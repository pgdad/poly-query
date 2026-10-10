;;;; binary.lisp — little-endian binary encoding helpers, CRC-32 and strict
;;;; UTF-8 decoding for the PQCF storage format.

(in-package #:polyquery)

#-little-endian
(error "PolyQuery's PQCF codec assumes a little-endian host")

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defun make-octets (n)
  (make-array n :element-type '(unsigned-byte 8) :initial-element 0))

(define-condition storage-corrupt (pq-error) ()
  (:default-initargs :code "STORAGE_CORRUPT"))

(defun storage-corrupt (format-control &rest args)
  (error 'storage-corrupt :code "STORAGE_CORRUPT"
                          :message (apply #'format nil format-control args)))

(defun storage-unsupported (format-control &rest args)
  (apply #'signal-pq-error "STORAGE_VERSION_UNSUPPORTED" format-control args))

;;; ------------------------------------------------------------------
;;; Fixed-width little-endian access (offsets are byte offsets)

(declaim (inline octets-u16 octets-u32 octets-i32 octets-i64 octets-f64
                 (setf octets-u32) (setf octets-i64) (setf octets-f64)))

(defun octets-u16 (buf off)
  (declare (type octets buf) (type fixnum off))
  (sb-sys:with-pinned-objects (buf) (sb-sys:sap-ref-16 (sb-sys:vector-sap buf) off)))

(defun octets-u32 (buf off)
  (declare (type octets buf) (type fixnum off))
  (sb-sys:with-pinned-objects (buf) (sb-sys:sap-ref-32 (sb-sys:vector-sap buf) off)))

(defun octets-i32 (buf off)
  (declare (type octets buf) (type fixnum off))
  (sb-sys:with-pinned-objects (buf) (sb-sys:signed-sap-ref-32 (sb-sys:vector-sap buf) off)))

(defun octets-i64 (buf off)
  (declare (type octets buf) (type fixnum off))
  (sb-sys:with-pinned-objects (buf) (sb-sys:signed-sap-ref-64 (sb-sys:vector-sap buf) off)))

(defun octets-f64 (buf off)
  (declare (type octets buf) (type fixnum off))
  (sb-sys:with-pinned-objects (buf) (sb-sys:sap-ref-double (sb-sys:vector-sap buf) off)))

(defun (setf octets-u32) (value buf off)
  (declare (type octets buf) (type fixnum off) (type (unsigned-byte 32) value))
  (sb-sys:with-pinned-objects (buf)
    (setf (sb-sys:sap-ref-32 (sb-sys:vector-sap buf) off) value)))

(defun (setf octets-i64) (value buf off)
  (declare (type octets buf) (type fixnum off) (type (signed-byte 64) value))
  (sb-sys:with-pinned-objects (buf)
    (setf (sb-sys:signed-sap-ref-64 (sb-sys:vector-sap buf) off) value)))

(defun (setf octets-f64) (value buf off)
  (declare (type octets buf) (type fixnum off) (type double-float value))
  (sb-sys:with-pinned-objects (buf)
    (setf (sb-sys:sap-ref-double (sb-sys:vector-sap buf) off) value)))

(defun (setf octets-i32) (value buf off)
  (declare (type octets buf) (type fixnum off) (type (signed-byte 32) value))
  (sb-sys:with-pinned-objects (buf)
    (setf (sb-sys:signed-sap-ref-32 (sb-sys:vector-sap buf) off) value)))

;;; ------------------------------------------------------------------
;;; CRC-32 (ISO-HDLC / zlib): reflected polynomial #xEDB88320

(declaim (type (simple-array (unsigned-byte 32) (256)) +crc32-table+))
(sb-ext:defglobal +crc32-table+
    (let ((table (make-array 256 :element-type '(unsigned-byte 32))))
      (dotimes (n 256 table)
        (let ((c n))
          (dotimes (k 8)
            (setf c (if (logbitp 0 c)
                        (logxor #xEDB88320 (ash c -1))
                        (ash c -1))))
          (setf (aref table n) c)))))

(defun crc32 (buf &key (start 0) (end (length buf)))
  "CRC-32 of the octets BUF[START, END)."
  (declare (type octets buf) (type fixnum start end)
           (optimize (speed 3) (safety 0)))
  (let ((crc #xFFFFFFFF)
        (table +crc32-table+))
    (declare (type (unsigned-byte 32) crc))
    (loop for i of-type fixnum from start below end
          do (setf crc (logxor (aref table (logand (logxor crc (aref buf i)) #xFF))
                               (ash crc -8))))
    (logxor crc #xFFFFFFFF)))

;;; ------------------------------------------------------------------
;;; UTF-8

(defun decode-utf8 (buf start end)
  "Decode the strictly valid UTF-8 octets BUF[START, END) into a string;
invalid input (overlong forms, surrogates, out-of-range or truncated
sequences) is STORAGE_CORRUPT."
  (declare (type octets buf) (type fixnum start end))
  ;; Fast path: pure ASCII.
  (when (loop for i of-type fixnum from start below end always (< (aref buf i) #x80))
    (let ((s (make-string (- end start))))
      (loop for i of-type fixnum from start below end
            for j of-type fixnum from 0
            do (setf (schar s j) (code-char (aref buf i))))
      (return-from decode-utf8 s)))
  (let ((out (make-array (- end start) :element-type 'character :fill-pointer 0))
        (i start))
    (declare (type fixnum i))
    (flet ((bad () (storage-corrupt "invalid UTF-8 in string data"))
           (cont (k)
             (let ((p (+ i k)))
               (unless (< p end) (storage-corrupt "truncated UTF-8 sequence"))
               (let ((b (aref buf p)))
                 (unless (= (logand b #xC0) #x80) (storage-corrupt "invalid UTF-8 continuation"))
                 (logand b #x3F)))))
      (loop while (< i end)
            do (let ((b (aref buf i)))
                 (multiple-value-bind (code len)
                     (cond ((< b #x80) (values b 1))
                           ((< b #xC2) (bad))
                           ((< b #xE0) (values (logior (ash (logand b #x1F) 6) (cont 1)) 2))
                           ((< b #xF0) (values (logior (ash (logand b #x0F) 12) (ash (cont 1) 6) (cont 2)) 3))
                           ((< b #xF5) (values (logior (ash (logand b #x07) 18) (ash (cont 1) 12)
                                                       (ash (cont 2) 6) (cont 3))
                                               4))
                           (t (bad)))
                   (when (or (and (= len 3) (< code #x800))
                             (and (= len 4) (< code #x10000))
                             (<= #xD800 code #xDFFF)
                             (> code #x10FFFF))
                     (bad))
                   (vector-push (code-char code) out)
                   (incf i len)))))
    (coerce out 'simple-string)))

(defun encode-utf8 (string)
  (sb-ext:string-to-octets string :external-format :utf-8))
