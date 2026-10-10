;;;; pqcf-read.lisp — PQCF v1 reader and validator (storage/pqcf-v1.md).
;;;;
;;;; READ-PQCF validates header, footer, metadata checksum and metadata
;;;; structure, and returns the table description with one segment per row
;;;; group. Column chunks are decoded by DECODE-CHUNK, which verifies the
;;;; chunk CRC and every value rule of §3.4 before producing a COLUMN-STORE;
;;;; this happens either immediately or lazily on first access.
;;;; Every violation is STORAGE_CORRUPT; unsupported versions, flags and
;;;; encodings are STORAGE_VERSION_UNSUPPORTED.

(in-package #:polyquery)

(defstruct chunk-desc
  (offset 0 :type fixnum)
  (length 0 :type fixnum)
  (crc 0 :type (unsigned-byte 32))
  (encoding :plain)                      ; :PLAIN :DICT :RLE
  (null-count 0 :type fixnum))

(defstruct pqcf-file
  "Validated metadata of a PQCF file."
  columns                                ; list of COLUMN-DEF
  indexes                                ; list of (name column-name kind)
  row-groups)                            ; list of (row-count . list of (CHUNK-DESC . CHUNK-STATS))

;;; ------------------------------------------------------------------
;;; Value ranges (types.md §1)

(defparameter *min-date-days* (days-from-civil 1 1 1))
(defparameter *max-date-days* (days-from-civil 9999 12 31))
(defparameter *min-timestamp* (* *min-date-days* +micros-per-day+))
(defparameter *max-timestamp* (1- (* (1+ *max-date-days*) +micros-per-day+)))

(defun value-in-type-range-p (v type)
  "True if the integer V is a valid stored value of TYPE (integer-kind types)."
  (ecase (type-kind type)
    (:int64 t)
    (:decimal (< (abs v) (pow10 (decimal-precision type))))
    (:date (<= *min-date-days* v *max-date-days*))
    (:timestamp (<= *min-timestamp* v *max-timestamp*))
    (:boolean (or (= v 0) (= v 1)))))

;;; ------------------------------------------------------------------
;;; Metadata validation

(defun meta-field (object key &key (required t))
  (multiple-value-bind (v found) (json-get object key)
    (when (and required (not found))
      (storage-corrupt "metadata is missing ~S" key))
    (values v found)))

(defun meta-integer (object key &key (min 0) (max most-positive-fixnum) (required t))
  (multiple-value-bind (v found) (meta-field object key :required required)
    (when found
      (unless (and (integerp v) (<= min v max))
        (storage-corrupt "metadata field ~S is invalid" key)))
    v))

(defun meta-array (object key &key (required t))
  (multiple-value-bind (v found) (meta-field object key :required required)
    (cond ((or (not found) (and (not required) (eq v :null))) #())
          ((simple-vector-p v) v)
          (t (storage-corrupt "metadata field ~S must be an array" key)))))

(defun meta-object (v what)
  (unless (json-object-p v) (storage-corrupt "~A must be an object" what))
  v)

(defun json-number-value (v)
  "A rational/double for a JSON number value, or NIL."
  (cond ((integerp v) v)
        ((jnum-p v) (multiple-value-bind (d status) (parse-float-text (jnum-text v))
                      (and (eq status :ok) d)))
        (t nil)))

(defun parse-stat-value (v type)
  "Chunk min/max statistic V (JSON) as a runtime value of TYPE, or NIL when
absent or not understood (statistics are only an optimization)."
  (handler-case
      (ecase (type-kind type)
        (:int64 (and (integerp v) (int64-p v) v))
        (:float64 (let ((n (json-number-value v)))
                    (and n (coerce n 'double-float))))
        (:decimal (and (stringp v)
                       (multiple-value-bind (x status)
                           (text-to-decimal v (decimal-precision type) (decimal-scale type))
                         (and (eq status :ok) x))))
        (:date (and (stringp v) (parse-date-text v)))
        (:timestamp (and (stringp v) (parse-timestamp-text v)))
        (:boolean (case v (:true t) (:false nil) (t nil)))
        (:string (and (stringp v) v)))
    (error () nil)))

(defun parse-encoding (name type)
  (unless (stringp name) (storage-corrupt "chunk encoding must be a string"))
  (let ((enc (cond ((string= name "PLAIN") :plain)
                   ((string= name "DICT") :dict)
                   ((string= name "RLE") :rle)
                   (t (storage-unsupported "unsupported chunk encoding ~S" name)))))
    (unless (ecase enc
              (:plain t)
              (:dict (eq (type-kind type) :string))
              (:rle (member (type-kind type) '(:boolean :int64 :decimal :date :timestamp))))
      (storage-corrupt "encoding ~A is not valid for type ~A" name (type-name-string type)))
    enc))

(defun parse-metadata-columns (meta)
  (let ((seen (make-hash-table :test 'equal)))
    (loop for c across (meta-array meta "columns")
          collect (let* ((obj (meta-object c "column"))
                         (name (meta-field obj "name"))
                         (type-name (meta-field obj "type")))
                    (unless (and (stringp name) (plusp (length name)))
                      (storage-corrupt "column names must be non-empty strings"))
                    (when (gethash (ascii-downcase name) seen)
                      (storage-corrupt "duplicate column name ~S" name))
                    (setf (gethash (ascii-downcase name) seen) t)
                    (unless (stringp type-name) (storage-corrupt "column type must be a string"))
                    (make-column-def name (parse-type-string type-name "STORAGE_CORRUPT"))))))

(defun parse-metadata-indexes (meta columns)
  (let ((seen (make-hash-table :test 'equal))
        (result '()))
    (loop for entry across (meta-array meta "indexes" :required nil)
          do (let* ((obj (meta-object entry "index"))
                    (name (meta-field obj "name"))
                    (column (meta-field obj "column"))
                    (kind (meta-field obj "kind")))
               (unless (and (stringp name) (plusp (length name)) (stringp column) (stringp kind))
                 (storage-corrupt "malformed index entry"))
               (unless (find column columns :key #'column-def-name :test #'ascii-string-equal)
                 (storage-corrupt "index ~A references unknown column ~A" name column))
               (when (gethash (ascii-downcase name) seen)
                 (storage-corrupt "duplicate index name ~A" name))
               (setf (gethash (ascii-downcase name) seen) t)
               ;; Index kinds this reader does not know are skipped (they
               ;; only affect performance, never results).
               (let ((k (cond ((string= kind "HASH") :hash) ((string= kind "BTREE") :btree))))
                 (when k (push (list name column k) result)))))
    (nreverse result)))

(defun parse-metadata-row-groups (meta columns data-end)
  (let ((ncols (length columns))
        (total 0))
    (values
     (loop for g across (meta-array meta "row_groups")
           collect (let* ((obj (meta-object g "row group"))
                          (n (meta-integer obj "row_count"))
                          (chunks (meta-array obj "chunks")))
                     (incf total n)
                     (unless (= (length chunks) ncols)
                       (storage-corrupt "row group has ~D chunks for ~D columns" (length chunks) ncols))
                     (cons n
                           (loop for c across chunks
                                 for def in columns
                                 for type = (column-def-type def)
                                 collect (let* ((obj (meta-object c "chunk"))
                                                (offset (meta-integer obj "offset" :min 8))
                                                (len (meta-integer obj "length"))
                                                (crc (meta-integer obj "crc32" :max #xFFFFFFFF))
                                                (encoding (parse-encoding (meta-field obj "encoding") type))
                                                (nulls (meta-integer obj "null_count" :max n)))
                                           (when (> (+ offset len) data-end)
                                             (storage-corrupt "chunk exceeds the data area"))
                                           (cons (make-chunk-desc :offset offset :length len :crc crc
                                                                  :encoding encoding :null-count nulls)
                                                 (make-chunk-stats
                                                  :null-count nulls
                                                  :min (parse-stat-value (json-get obj "min") type)
                                                  :max (parse-stat-value (json-get obj "max") type))))))))
     total)))

(defun read-pqcf (source)
  "Validate the structure of the PQCF file in SOURCE. Returns a PQCF-FILE."
  (let ((size (file-source-size source)))
    (when (< size 8) (storage-corrupt "file too short for a PQCF header"))
    (let ((header (source-copy source 0 8)))
      (unless (equalp (subseq header 0 4) *pqcf-magic*)
        (storage-corrupt "bad header magic"))
      (let ((version (octets-u16 header 4))
            (flags (octets-u16 header 6)))
        (when (zerop version) (storage-corrupt "format version 0"))
        (when (> version +pqcf-version+)
          (storage-unsupported "PQCF format version ~D is not supported" version))
        (unless (zerop flags)
          (storage-unsupported "PQCF flags ~D are not supported" flags))))
    (when (< size 20) (storage-corrupt "file too short for a PQCF footer"))
    (let* ((footer (source-copy source (- size 12) 12))
           (m (octets-u32 footer 0))
           (crc (octets-u32 footer 4))
           (meta-start (- size 12 m)))
      (unless (equalp (subseq footer 8 12) *pqcf-magic*)
        (storage-corrupt "bad trailer magic"))
      (when (< meta-start 8) (storage-corrupt "metadata length out of range"))
      (let* ((bytes (source-copy source meta-start m))
             (meta (progn
                     (unless (= crc (crc32 bytes)) (storage-corrupt "metadata checksum mismatch"))
                     (handler-case (parse-json (decode-utf8 bytes 0 m) :duplicate-keys :first)
                       (json-syntax-error () (storage-corrupt "metadata is not valid JSON"))))))
        (meta-object meta "metadata")
        (unless (eql (meta-field meta "format_version") +pqcf-version+)
          (storage-corrupt "metadata format_version does not match the header"))
        (unless (stringp (meta-field meta "table"))
          (storage-corrupt "metadata table must be a string"))
        (let* ((row-count (meta-integer meta "row_count"))
               (columns (parse-metadata-columns meta))
               (indexes (parse-metadata-indexes meta columns)))
          (multiple-value-bind (groups total) (parse-metadata-row-groups meta columns meta-start)
            (unless (= total row-count)
              (storage-corrupt "row_count ~D does not match the row groups (~D)" row-count total))
            (check-padding source groups meta-start)
            (make-pqcf-file :columns columns :indexes indexes :row-groups groups)))))))

(defun check-padding (source groups data-end)
  "Bytes of the data area [8, DATA-END) not covered by any chunk may only be
zero padding; anything else is damage no checksum would catch."
  (let ((ranges (sort (loop for (nil . chunks) in groups
                            nconc (loop for (desc . nil) in chunks
                                        collect (cons (chunk-desc-offset desc)
                                                      (chunk-desc-length desc))))
                      #'< :key #'car))
        (pos 8))
    (flet ((check-zero (start end)
             (when (< start end)
               (multiple-value-bind (buf base) (source-range source start (- end start))
                 (unless (loop for i from base below (+ base (- end start))
                               always (zerop (aref buf i)))
                   (storage-corrupt "non-zero bytes outside the column chunks"))))))
      (loop for (offset . length) in ranges
            do (check-zero pos offset)
               (setf pos (max pos (+ offset length))))
      (check-zero pos data-end))))

;;; ------------------------------------------------------------------
;;; Chunk decoding

(defun decode-chunk (source desc n type)
  "Verify and decode the chunk DESC of N rows of TYPE into a COLUMN-STORE."
  (declare (type fixnum n))
  (let ((length (chunk-desc-length desc))
        (null-count (chunk-desc-null-count desc)))
    (multiple-value-bind (buf base) (source-range source (chunk-desc-offset desc) length)
      (declare (type octets buf) (type fixnum base))
      (unless (= (crc32 buf :start base :end (+ base length)) (chunk-desc-crc desc))
        (storage-corrupt "chunk checksum mismatch"))
      (let ((pos base)
            (end (+ base length))
            (validity nil))
        (declare (type fixnum pos end))
        (flet ((need (bytes)
                 (when (> (+ pos bytes) end) (storage-corrupt "chunk is truncated"))))
          (when (plusp null-count)
            (let ((nbytes (ceiling n 8)))
              (need nbytes)
              (setf validity (make-array n :element-type 'bit))
              (let ((zeros 0))
                (declare (type fixnum zeros))
                (dotimes (i n)
                  (let ((bit (ldb (byte 1 (logand i 7)) (aref buf (+ pos (ash i -3))))))
                    (setf (sbit validity i) bit)
                    (when (zerop bit) (incf zeros))))
                (unless (= zeros null-count)
                  (storage-corrupt "validity bitmap does not match null_count")))
              (incf pos nbytes)))
          (flet ((valid-p (i) (or (null validity) (= 1 (sbit validity i)))))
            (declare (inline valid-p))
            (let ((store
                    (ecase (chunk-desc-encoding desc)
                      (:plain (multiple-value-bind (store used)
                                  (decode-plain buf pos end n type validity #'valid-p)
                                (setf pos (+ pos used))
                                store))
                      (:dict (multiple-value-bind (store used)
                                 (decode-dict buf pos end n validity #'valid-p)
                               (setf pos (+ pos used))
                               store))
                      (:rle (multiple-value-bind (store used)
                                (decode-rle buf pos end n type validity #'valid-p)
                              (setf pos (+ pos used))
                              store)))))
              (unless (= pos end)
                (storage-corrupt "chunk has ~D trailing bytes" (- end pos)))
              store)))))))

(defun check-room (pos bytes end)
  (when (> (+ pos bytes) end) (storage-corrupt "chunk is truncated")))

(defun decode-string-offsets (buf pos end count)
  "Read COUNT+1 u32 offsets at POS. Returns (values offsets data-start
data-end) after checking they are well-formed and within END."
  (check-room pos (* 4 (1+ count)) end)
  (let ((offsets (make-array (1+ count) :element-type '(unsigned-byte 32))))
    (dotimes (i (1+ count))
      (setf (aref offsets i) (octets-u32 buf (+ pos (* 4 i)))))
    (unless (zerop (aref offsets 0)) (storage-corrupt "string offsets must start at 0"))
    (loop for i from 1 to count
          unless (<= (aref offsets (1- i)) (aref offsets i))
            do (storage-corrupt "string offsets are decreasing"))
    (let ((data-start (+ pos (* 4 (1+ count)))))
      (check-room data-start (aref offsets count) end)
      (values offsets data-start (+ data-start (aref offsets count))))))

(defun decode-plain (buf pos end n type validity valid-p)
  "Returns (values store bytes-used)."
  (declare (type octets buf) (type fixnum pos end n) (type function valid-p))
  (ecase (type-kind type)
    (:boolean
     (let ((nbytes (ceiling n 8)))
       (check-room pos nbytes end)
       (let ((bits (make-array n :element-type 'bit)))
       (dotimes (i n)
         (setf (sbit bits i) (ldb (byte 1 (logand i 7)) (aref buf (+ pos (ash i -3))))))
       (when validity (bit-and bits validity bits))
       (values (make-bool-column :length n :validity validity :values bits) nbytes))))
    ((:int64 :decimal :timestamp :date)
     (let* ((width (if (eq type :date) 4 8))
            (out (progn (check-room pos (* width n) end)
                        (make-array n :element-type '(signed-byte 64) :initial-element 0)))
            (check (not (eq type :int64))))
       (dotimes (i n)
         (when (funcall valid-p i)
           (let ((v (if (= width 4)
                        (octets-i32 buf (+ pos (* 4 i)))
                        (octets-i64 buf (+ pos (* 8 i))))))
             (when (and check (not (value-in-type-range-p v type)))
               (storage-corrupt "value out of range for ~A" (type-name-string type)))
             (setf (aref out i) v))))
       (values (make-int-column :length n :validity validity :values out) (* width n))))
    (:float64
     (let ((out (progn (check-room pos (* 8 n) end)
                       (make-array n :element-type 'double-float :initial-element 0d0))))
       (dotimes (i n)
         (when (funcall valid-p i)
           (let ((d (octets-f64 buf (+ pos (* 8 i)))))
             (unless (finite-double-p d) (storage-corrupt "non-finite FLOAT64 value"))
             (setf (aref out i) d))))
       (values (make-float-column :length n :validity validity :values out) (* 8 n))))
    (:string
     (multiple-value-bind (offsets data-start data-end) (decode-string-offsets buf pos end n)
       (let ((out (make-array n :initial-element "")))
         (dotimes (i n)
           (when (funcall valid-p i)
             (setf (svref out i) (decode-utf8 buf (+ data-start (aref offsets i))
                                              (+ data-start (aref offsets (1+ i)))))))
         (values (make-string-column :length n :validity validity :values out)
                 (- data-end pos)))))))

(defun decode-dict (buf pos end n validity valid-p)
  (declare (type octets buf) (type fixnum pos end n) (type function valid-p))
  (check-room pos 4 end)
  (let ((d (octets-u32 buf pos)))
    (multiple-value-bind (offsets data-start data-end) (decode-string-offsets buf (+ pos 4) end d)
      (let ((dict (make-array d))
            (codes (progn (check-room data-end (* 4 n) end)
                          (make-array n :element-type '(unsigned-byte 32) :initial-element 0))))
        (dotimes (i d)
          (setf (svref dict i) (decode-utf8 buf (+ data-start (aref offsets i))
                                            (+ data-start (aref offsets (1+ i))))))
        (dotimes (i n)
          (when (funcall valid-p i)
            (let ((code (octets-u32 buf (+ data-end (* 4 i)))))
              (unless (< code d) (storage-corrupt "dictionary code out of range"))
              (setf (aref codes i) code))))
        (values (make-dict-column :length n :validity validity :codes codes :dictionary dict)
                (- (+ data-end (* 4 n)) pos))))))

(defun decode-rle (buf pos end n type validity valid-p)
  (declare (type octets buf) (type fixnum pos end n) (type function valid-p))
  (check-room pos 4 end)
  (let* ((runs (octets-u32 buf pos))
         (bytes (+ 4 (* 12 runs)))
         (row 0)
         (check (not (eq type :int64))))
    (declare (type fixnum row))
    (check-room pos bytes end)
    ;; Validate the run lengths before allocating N values.
    (unless (= n (loop for r below runs
                       for count = (octets-u32 buf (+ pos 4 (* 12 r) 8))
                       when (zerop count) do (storage-corrupt "invalid RLE run length")
                       sum count))
      (storage-corrupt "RLE runs do not cover the ~D rows of the chunk" n))
    (let ((out (make-array n :element-type '(signed-byte 64) :initial-element 0)))
      (dotimes (r runs)
        (let* ((at (+ pos 4 (* 12 r)))
               (value (octets-i64 buf at))
               (count (octets-u32 buf (+ at 8))))
          (dotimes (k count)
            (when (funcall valid-p row)
              (when (and check (not (value-in-type-range-p value type)))
                (storage-corrupt "RLE value out of range for ~A" (type-name-string type)))
              (setf (aref out row) value))
            (incf row))))
      (values (if (eq (type-kind type) :boolean)
                  (let ((bits (make-array n :element-type 'bit)))
                    (dotimes (i n) (setf (sbit bits i) (aref out i)))
                    (make-bool-column :length n :validity validity :values bits))
                  (make-int-column :length n :validity validity :values out))
              bytes))))

;;; ------------------------------------------------------------------
;;; Tables

(defun pqcf-segments (source file &key lazy)
  "Segments of the PQCF-FILE's row groups. With LAZY, chunks are decoded on
first access; otherwise all chunks are verified and decoded now."
  (let ((types (mapcar #'column-def-type (pqcf-file-columns file)))
        (start 0))
    (loop for (n . chunks) in (pqcf-file-row-groups file)
          collect (let ((seg (make-segment
                              :start start :count n
                              :columns (map 'simple-vector
                                            (lambda (chunk type)
                                              (let ((desc (car chunk)) (n n))
                                                (if lazy
                                                    (make-lazy-chunk
                                                     (lambda () (decode-chunk source desc n type)))
                                                    (decode-chunk source desc n type))))
                                            chunks types)
                              :stats (map 'simple-vector #'cdr chunks))))
                    (incf start n)
                    seg))))

(defun segments-to-row-layout (segments width)
  "Row-layout copies of column-layout SEGMENTS (decoding every chunk)."
  (mapcar (lambda (seg)
            (let* ((n (segment-count seg))
                   (readers (loop for k below width collect (segment-column-reader seg k)))
                   (rows (make-array n)))
              (dotimes (i n)
                (let ((row (make-array width)))
                  (loop for r in readers for k from 0
                        do (setf (svref row k) (funcall (the function r) i)))
                  (setf (svref rows i) row)))
              (make-segment :start (segment-start seg) :count n :rows rows
                            :stats (segment-stats seg))))
          segments))

(defun load-pqcf-table (native-path name &key mmap (layout :column))
  "Open the PQCF file at NATIVE-PATH as a table called NAME. Returns
(values table index-specs) where INDEX-SPECS are (name column-name kind)."
  (let* ((source (open-file-source native-path :mmap mmap))
         (file (read-pqcf source))
         (columns (pqcf-file-columns file))
         (segments (pqcf-segments source file :lazy (and mmap (eq layout :column)))))
    (values (make-table-from-segments name columns
                                      (if (eq layout :row)
                                          (segments-to-row-layout segments (length columns))
                                          segments)
                                      :layout layout
                                      :source (if (file-source-mapped source) :mmap :file))
            (pqcf-file-indexes file))))
