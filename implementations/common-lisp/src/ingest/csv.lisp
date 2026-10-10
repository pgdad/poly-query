;;;; csv.lisp — RFC 4180 CSV ingestion (ingestion.md §1).
;;;;
;;;; The parser works on raw UTF-8 octets: all structural characters are
;;;; ASCII, so fields can be located without decoding and only field contents
;;;; are decoded. A field is represented as NIL (unquoted empty => NULL),
;;;; :QUOTED-EMPTY, or its text.

(in-package #:polyquery)

(deftype octets () '(simple-array (unsigned-byte 8) (*)))

(defun decode-field (bytes start end)
  "Decode BYTES[START,END) as UTF-8 text."
  (declare (type octets bytes) (type fixnum start end))
  (when (> (- end start) +max-field-bytes+)
    (ingest-error "field longer than 16 MiB"))
  (if (loop for i of-type fixnum from start below end always (< (aref bytes i) 128))
      (let ((s (make-string (- end start))))
        (loop for i of-type fixnum from start below end
              for j of-type fixnum from 0
              do (setf (schar s j) (code-char (aref bytes i))))
        s)
      (handler-case (sb-ext:octets-to-string bytes :start start :end end :external-format :utf-8)
        (error () (ingest-error "invalid UTF-8 in input")))))

(defun parse-csv-records (bytes delimiter fn)
  "Split BYTES into records, calling FN with each record (a list of fields)
and its 1-based record number."
  (declare (type octets bytes))
  (let* ((n (length bytes))
         (delim (char-code delimiter))
         (i (if (and (>= n 3) (= (aref bytes 0) #xEF) (= (aref bytes 1) #xBB) (= (aref bytes 2) #xBF))
                3 0))
         (record-no 0)
         (buf (make-array 64 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0)))
    (declare (type fixnum n i delim record-no))
    (macrolet ((at (k) `(aref bytes ,k)))
      (loop while (< i n) do
        (cond
          ;; completely empty lines are ignored
          ((= (at i) 10) (incf i))
          ((and (= (at i) 13) (< (1+ i) n) (= (at (1+ i)) 10)) (incf i 2))
          (t
           (incf record-no)
           (let ((fields '()))
             (loop
               (if (and (< i n) (= (at i) 34))
                   ;; quoted field
                   (progn
                     (incf i)
                     (setf (fill-pointer buf) 0)
                     (loop
                       (when (>= i n)
                         (ingest-error "unterminated quoted field in record ~D" record-no))
                       (let ((c (at i)))
                         (cond ((/= c 34) (vector-push-extend c buf) (incf i))
                               ((and (< (1+ i) n) (= (at (1+ i)) 34))
                                (vector-push-extend 34 buf) (incf i 2))
                               (t (incf i) (return)))))
                     (push (if (zerop (fill-pointer buf))
                               :quoted-empty
                               (let ((copy (make-array (fill-pointer buf) :element-type '(unsigned-byte 8))))
                                 (replace copy buf)
                                 (decode-field copy 0 (length copy))))
                           fields)
                     (unless (or (>= i n) (= (at i) delim) (= (at i) 10)
                                 (and (= (at i) 13) (< (1+ i) n) (= (at (1+ i)) 10)))
                       (ingest-error "unexpected character after closing quote in record ~D" record-no)))
                   ;; unquoted field
                   (let ((start i))
                     (loop while (and (< i n)
                                      (/= (at i) delim)
                                      (/= (at i) 10)
                                      (not (and (= (at i) 13) (< (1+ i) n) (= (at (1+ i)) 10))))
                           do (incf i))
                     (push (if (= start i) nil (decode-field bytes start i)) fields)))
               ;; after a field: delimiter, record terminator or end of input
               (cond ((>= i n) (return))
                     ((= (at i) delim) (incf i))
                     ((= (at i) 10) (incf i) (return))
                     (t (incf i 2) (return))))
             (funcall fn (nreverse fields) record-no))))))))

(defun field-text-for-type (field type)
  "Text to convert for FIELD in a column of TYPE, or NIL for NULL. For
non-STRING types the text is trimmed, and a field that is empty after
trimming is NULL (consistent with inference, ingestion.md §1.1)."
  (cond ((null field) nil)
        ((eq field :quoted-empty) (if (eq type :string) "" nil))
        ((eq type :string) field)
        (t (let ((text (trim-spaces-tabs field)))
             (if (zerop (length text)) nil text)))))

(defun convert-text-column (fields type column-name first-record &key explicit)
  "Convert a vector of CSV fields to a SIMPLE-VECTOR of values of TYPE.
Conversion failures are CONVERSION_ERRORs with explicit schemas (inferred
types always convert)."
  (let* ((n (length fields))
         (out (make-array n)))
    (dotimes (i n out)
      (let ((text (field-text-for-type (aref fields i) type)))
        (setf (svref out i)
              (if (null text)
                  +null+
                  (multiple-value-bind (v status) (text-to-value text type)
                    (if (eq status :ok)
                        v
                        (signal-pq-error-with-details
                         "CONVERSION_ERROR"
                         (list (cons "record" (+ first-record i)) (cons "column_name" column-name))
                         "record ~D, column ~A: cannot convert ~S to ~A~:[~; (inferred)~]"
                         (+ first-record i) column-name text (type-name-string type)
                         (not explicit))))))))))

(defun ingest-csv (bytes spec)
  "Parse CSV octets according to SPEC. Returns (values column-defs column-data row-count)."
  (let* ((schema (ingest-spec-schema spec))
         (header-p (ingest-spec-header spec))
         (header nil)
         (ncols (if (and schema (not header-p)) (length schema) nil))
         (columns nil)                  ; per column: adjustable vector of fields
         (first-data-record (if header-p 2 1))
         (row-count 0))
    (flet ((init-columns (n)
             (setf ncols n
                   columns (coerce (loop repeat n
                                         collect (make-array 16 :adjustable t :fill-pointer 0))
                                   'simple-vector))))
      (when ncols (init-columns ncols))
      (parse-csv-records
       bytes (ingest-spec-delimiter spec)
       (lambda (fields record-no)
         (cond
           ((and header-p (null header))
            (setf header (mapcar (lambda (f) (if (stringp f) f "")) fields))
            (init-columns (length header)))
           (t
            (unless (= (length fields) ncols)
              (signal-pq-error-with-details
               "INGEST_ERROR" (list (cons "record" record-no))
               "record ~D has ~D fields, expected ~D" record-no (length fields) ncols))
            (incf row-count)
            (when (> row-count (ingest-spec-max-rows spec))
              (check-row-limit row-count spec))
            (loop for f in fields
                  for col across columns
                  do (vector-push-extend f col)))))))
    (when (and header-p (null header))
      (ingest-error "CSV input has no header record"))
    (let ((names (if header-p header (mapcar #'column-def-name schema))))
      (check-column-names names)
      (when (and schema header-p)
        (unless (and (= (length schema) (length header))
                     (every (lambda (c h) (ascii-string-equal (column-def-name c) h)) schema header))
          (ingest-error "CSV header does not match the explicit schema")))
      (let ((defs (if schema
                      (mapcar (lambda (c) (make-column-def (column-def-name c) (column-def-type c))) schema)
                      (loop for name in names
                            for col across columns
                            collect (make-column-def name (infer-text-column-type col))))))
        (values defs
                (loop for def in defs
                      for col across columns
                      collect (convert-text-column col (column-def-type def) (column-def-name def)
                                                   first-data-record :explicit (not (null schema))))
                row-count)))))
