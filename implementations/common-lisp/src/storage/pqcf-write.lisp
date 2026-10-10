;;;; pqcf-write.lisp — PQCF v1 writer (storage/pqcf-v1.md).
;;;;
;;;; The file is produced row group by row group, column by column: each
;;;; chunk is encoded into an octet vector (validity bitmap + values), written
;;;; at the next 8-byte aligned offset and described in the metadata JSON,
;;;; which is followed by the footer (length, CRC-32, magic).

(in-package #:polyquery)

(defparameter *pqcf-writer-name* "polyquery-common-lisp")
(defparameter *default-row-group-size* 65536)
(defconstant +pqcf-version+ 1)
(defparameter *pqcf-magic* (coerce #(80 81 67 70) '(simple-array (unsigned-byte 8) (4))))

;;; ------------------------------------------------------------------
;;; Chunk encoding

(defun bitmap-octets (n bit-fn)
  "LSB-first bitmap of N bits; bit I is (funcall BIT-FN I)."
  (declare (type fixnum n) (type function bit-fn))
  (let ((out (make-octets (ceiling n 8))))
    (dotimes (i n out)
      (when (funcall bit-fn i)
        (setf (aref out (ash i -3)) (logior (aref out (ash i -3)) (ash 1 (logand i 7))))))))

(defun rle-integer (v type)
  "The i64 representation of a non-NULL value of TYPE in PLAIN/RLE encodings."
  (if (eq (type-kind type) :boolean) (if v 1 0) v))

(defun count-runs (values type)
  "Number of RLE runs needed for VALUES (NULL slots continue the current run)."
  (declare (type simple-vector values))
  (let ((runs 0) (current nil))
    (loop for v across values
          unless (null-value-p v)
            do (let ((x (rle-integer v type)))
                 (unless (eql x current)
                   (incf runs)
                   (setf current x))))
    (max runs (if (plusp (length values)) 1 0))))

(defun count-distinct-values (values)
  (let ((seen (make-hash-table :test 'equal)))
    (loop for v across values
          unless (null-value-p v) do (setf (gethash v seen) t))
    (hash-table-count seen)))

(defun encode-plain (values type)
  (declare (type simple-vector values))
  (let ((n (length values)))
    (ecase (type-kind type)
      (:boolean (bitmap-octets n (lambda (i) (eq (svref values i) t))))
      ((:int64 :decimal :timestamp)
       (let ((out (make-octets (* 8 n))))
         (dotimes (i n out)
           (let ((v (svref values i)))
             (unless (null-value-p v) (setf (octets-i64 out (* 8 i)) v))))))
      (:date
       (let ((out (make-octets (* 4 n))))
         (dotimes (i n out)
           (let ((v (svref values i)))
             (unless (null-value-p v) (setf (octets-i32 out (* 4 i)) v))))))
      (:float64
       (let ((out (make-octets (* 8 n))))
         (dotimes (i n out)
           (let ((v (svref values i)))
             (unless (null-value-p v) (setf (octets-f64 out (* 8 i)) v))))))
      (:string (encode-string-list (map 'list (lambda (v) (if (null-value-p v) "" v)) values))))))

(defun encode-string-list (strings)
  "(n+1) u32 offsets followed by the concatenated UTF-8 bytes of STRINGS."
  (let* ((encoded (mapcar #'encode-utf8 strings))
         (n (length encoded))
         (total (reduce #'+ encoded :key #'length))
         (out (make-octets (+ (* 4 (1+ n)) total)))
         (pos (* 4 (1+ n)))
         (offset 0))
    (setf (octets-u32 out 0) 0)
    (loop for bytes in encoded
          for i from 1
          do (replace out bytes :start1 pos)
             (incf pos (length bytes))
             (incf offset (length bytes))
             (setf (octets-u32 out (* 4 i)) offset))
    out))

(defun encode-dict (values)
  (declare (type simple-vector values))
  (let ((positions (make-hash-table :test 'equal))
        (dict '())
        (codes (make-octets (* 4 (length values)))))
    (loop for v across values
          for i from 0
          unless (null-value-p v)
            do (setf (octets-u32 codes (* 4 i))
                     (or (gethash v positions)
                         (progn (push v dict)
                                (setf (gethash v positions) (1- (length dict)))))))
    (let ((header (make-octets 4)))
      (setf (octets-u32 header 0) (length dict))
      (concatenate 'octets header (encode-string-list (nreverse dict)) codes))))

(defun encode-rle (values type)
  (declare (type simple-vector values))
  (let ((runs '()) (current nil) (len 0))
    (loop for v across values
          do (let ((x (if (null-value-p v) (or current 0) (rle-integer v type))))
               (if (and current (eql x current))
                   (incf len)
                   (progn
                     (when current (push (cons current len) runs))
                     (setf current x len 1)))))
    (when current (push (cons current len) runs))
    (setf runs (nreverse runs))
    (let ((out (make-octets (+ 4 (* 12 (length runs))))))
      (setf (octets-u32 out 0) (length runs))
      (loop for (value . count) in runs
            for pos from 4 by 12
            do (setf (octets-i64 out pos) value
                     (octets-u32 out (+ pos 8)) count))
      out)))

(defun choose-encoding (values type mode)
  "Encoding name for a chunk. MODE is :AUTO, :PLAIN, :DICT or :RLE; forced
encodings that do not apply to TYPE fall back to PLAIN."
  (let ((n (length values))
        (kind (type-kind type)))
    (flet ((rle-ok () (member kind '(:boolean :int64 :decimal :date :timestamp)))
           (dict-ok () (eq kind :string)))
      (ecase mode
        (:plain "PLAIN")
        (:rle (if (rle-ok) "RLE" "PLAIN"))
        (:dict (if (dict-ok) "DICT" "PLAIN"))
        (:auto
         (cond ((zerop n) "PLAIN")
               ((and (rle-ok) (< (count-runs values type) (/ n 4))) "RLE")
               ((and (dict-ok) (< (count-distinct-values values) (/ n 2))) "DICT")
               (t "PLAIN")))))))

(defun chunk-min-max (values type)
  "Exact (values min max) of the non-NULL VALUES, or NILs if there are none."
  (let ((cmp (make-comparator type)) (lo nil) (hi nil))
    (declare (type function cmp))
    (loop for v across values
          unless (null-value-p v)
            do (when (or (null lo) (minusp (the fixnum (funcall cmp v lo)))) (setf lo v))
               (when (or (null hi) (plusp (the fixnum (funcall cmp v hi)))) (setf hi v)))
    (values lo hi)))

(defun encode-chunk (values type mode)
  "Encode one column chunk. Returns (values octets encoding null-count)."
  (declare (type simple-vector values))
  (let* ((n (length values))
         (null-count (count +null+ values))
         (encoding (choose-encoding values type mode))
         (body (cond ((string= encoding "RLE") (encode-rle values type))
                     ((string= encoding "DICT") (encode-dict values))
                     (t (encode-plain values type)))))
    (values (if (plusp null-count)
                (concatenate 'octets
                             (bitmap-octets n (lambda (i) (not (null-value-p (svref values i)))))
                             body)
                body)
            encoding
            null-count)))

;;; ------------------------------------------------------------------
;;; Whole files

(defun table-column-accessor (table k)
  "Function (row-id) -> value of column K."
  (let ((segs (table-segments table)))
    (if (= (length segs) 1)
        (segment-column-reader (svref segs 0) k)
        (let ((readers (map 'simple-vector (lambda (seg) (segment-column-reader seg k)) segs)))
          (lambda (row-id)
            (let ((s (find-segment-index table row-id)))
              (funcall (the function (svref readers s))
                       (- row-id (segment-start (svref segs s))))))))))

(defun write-pqcf (stream table indexes &key (row-group-size *default-row-group-size*)
                                             (encoding :auto))
  "Write TABLE (with the metadata of INDEXES) as a PQCF v1 file to the octet
STREAM. Returns the number of bytes written."
  (let* ((defs (table-columns table))
         (ncols (length defs))
         (row-count (table-row-count table))
         (accessors (loop for k below ncols collect (table-column-accessor table k)))
         (position 0)
         (row-groups '()))
    (labels ((emit (octets)
               (write-sequence octets stream)
               (incf position (length octets)))
             (pad ()
               (let ((r (mod position 8)))
                 (unless (zerop r) (emit (make-octets (- 8 r)))))))
      (emit *pqcf-magic*)
      (let ((header (make-octets 4)))
        (setf (aref header 0) +pqcf-version+)
        (emit header))
      (loop for start from 0 below row-count by row-group-size
            for n = (min row-group-size (- row-count start))
            do (check-interrupts)
               (let ((chunks '()))
                 (loop for accessor in accessors
                       for def across defs
                       for type = (column-def-type def)
                       do (let ((values (make-array n)))
                            (dotimes (i n)
                              (setf (svref values i) (funcall (the function accessor) (+ start i))))
                            (multiple-value-bind (octets encoding null-count)
                                (encode-chunk values type encoding)
                              (pad)
                              (let ((offset position))
                                (emit octets)
                                (multiple-value-bind (lo hi)
                                    (if (eq (type-kind type) :string)
                                        (values nil nil)
                                        (chunk-min-max values type))
                                  (push (apply #'jobj "offset" offset "length" (length octets)
                                               "crc32" (crc32 octets) "encoding" encoding
                                               "null_count" null-count
                                               (when lo
                                                 (list "min" (value-to-json lo type)
                                                       "max" (value-to-json hi type))))
                                        chunks))))))
                 (push (jobj "row_count" n "chunks" (nreverse chunks)) row-groups)))
      (pad)
      (let* ((metadata (jobj "format_version" +pqcf-version+
                             "writer" (format nil "~A ~A" *pqcf-writer-name* *engine-version*)
                             "table" (table-name table)
                             "row_count" row-count
                             "columns" (columns-json defs)
                             "indexes" (mapcar #'table-index-json indexes)
                             "row_groups" (nreverse row-groups)))
             (bytes (encode-utf8 (json-to-string metadata)))
             (footer (make-octets 8)))
        (emit bytes)
        (setf (octets-u32 footer 0) (length bytes)
              (octets-u32 footer 4) (crc32 bytes))
        (emit footer)
        (emit *pqcf-magic*)
        position))))
