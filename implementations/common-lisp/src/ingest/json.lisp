;;;; json.lisp — JSON array and JSON Lines ingestion (ingestion.md §2).

(in-package #:polyquery)

(defun parse-json-for-ingest (text &key (start 0) (end (length text)))
  (handler-case (parse-json text :start start :end end :duplicate-keys :error)
    (json-syntax-error (e)
      (ingest-error "malformed JSON: ~A" (json-syntax-error-message e)))))

(defun json-ingest-objects (text format)
  "Return the list of top-level JSON-OBJECTs of the input."
  (ecase format
    (:json
     (let ((doc (parse-json-for-ingest text)))
       (unless (simple-vector-p doc)
         (ingest-error "JSON input must be an array of objects"))
       (loop for item across doc
             unless (json-object-p item)
               do (ingest-error "JSON array element is not an object")
             collect item)))
    (:jsonl
     (let ((objects '()) (n (length text)) (start 0) (line-no 0))
       (loop while (< start n) do
         (let* ((nl (or (position #\Newline text :start start) n))
                (b (or (position-if-not #'json-whitespace-p text :start start :end nl) nl))
                (e (if (= b nl) nl (1+ (position-if-not #'json-whitespace-p text :start b :end nl :from-end t)))))
           (incf line-no)
           (when (< b e)
             (let ((obj (parse-json-for-ingest text :start b :end e)))
               (unless (json-object-p obj)
                 (ingest-error "line ~D is not a JSON object" line-no))
               (push obj objects)))
           (setf start (1+ nl))))
       (nreverse objects)))))

(defun json-whitespace-p (c)
  (member c '(#\Space #\Tab #\Return #\Newline)))

(defun json-value-kind (v)
  (cond ((eq v :null) :null)
        ((or (eq v :true) (eq v :false)) :boolean)
        ((integerp v) (if (int64-p v) :int :float))
        ((jnum-p v) :float)
        ((stringp v) :string)
        (t (ingest-error "nested objects or arrays are not supported as values"))))

(defun json-number-text (v)
  (if (integerp v) (format nil "~D" v) (jnum-text v)))

(defun json-number-to-double (v)
  (multiple-value-bind (d status) (parse-float-text (json-number-text v))
    (if (eq status :ok) d (ingest-error "JSON number ~A is not a finite FLOAT64" (json-number-text v)))))

(defun infer-json-column-type (values)
  (let ((kinds 0))
    (loop for v across values
          do (setf kinds (logior kinds (ecase (json-value-kind v)
                                         (:null 0) (:boolean 1) (:int 2) (:float 4) (:string 8)))))
    (case kinds
      (0 :string)
      (1 :boolean)
      (2 :int64)
      ((4 6) :float64)
      (8 (let ((all-date t) (all-temporal t))
           (loop for v across values
                 when (stringp v)
                   do (unless (parse-date-text v)
                        (setf all-date nil)
                        (unless (parse-timestamp-text v)
                          (setf all-temporal nil)
                          (return))))
           (cond (all-date :date) (all-temporal :timestamp) (t :string))))
      (t (ingest-error "column mixes incompatible JSON value types")))))

(defun convert-json-inferred (v type)
  (if (eq v :null)
      +null+
      (ecase type
        (:boolean (eq v :true))
        (:int64 v)
        (:float64 (json-number-to-double v))
        (:string v)
        (:date (parse-date-text v))
        (:timestamp (parse-timestamp-text v :allow-date-only t)))))

(defun convert-json-explicit (v type record column-name)
  "Convert JSON value V to TYPE per ingestion.md §2.2."
  (flet ((fail ()
           (signal-pq-error-with-details
            "CONVERSION_ERROR" (list (cons "record" record) (cons "column_name" column-name))
            "record ~D, column ~A: cannot convert ~A to ~A"
            record column-name (json-to-string v) (type-name-string type)))
         (from-text (text)
           (multiple-value-bind (value status) (text-to-value text type)
             (if (eq status :ok) value :fail))))
    (let* ((kind (type-kind type))
           (result
             (cond ((eq v :null) +null+)
                   ((or (eq v :true) (eq v :false))
                    (if (eq kind :boolean) (eq v :true) :fail))
                   ((or (integerp v) (jnum-p v))
                    (if (member kind '(:int64 :float64 :decimal))
                        (from-text (json-number-text v))
                        :fail))
                   ((stringp v)
                    (case kind
                      ((:date :timestamp :string) (from-text v))
                      ((:int64 :float64 :decimal) (from-text (trim-spaces-tabs v)))
                      (t :fail)))
                   (t (ingest-error "nested objects or arrays are not supported as values")))))
      (if (eq result :fail) (fail) result))))

(defun ingest-json (text spec)
  "Parse JSON/JSONL TEXT according to SPEC. Returns (values column-defs column-data row-count)."
  (let* ((objects (json-ingest-objects text (ingest-spec-format spec)))
         (schema (ingest-spec-schema spec))
         (nrows (length objects))
         (names '())                         ; column names in first-appearance order
         (index (make-hash-table :test 'equal)))
    (check-row-limit nrows spec)
    (if schema
        (loop for c in schema
              for i from 0
              do (setf (gethash (ascii-downcase (column-def-name c)) index) i)
                 (push (column-def-name c) names))
        (dolist (obj objects)
          (dolist (pair (json-object-pairs obj))
            (unless (gethash (car pair) index)
              (setf (gethash (car pair) index) (length names))
              (push (car pair) names)))))
    (setf names (nreverse names))
    (check-column-names names)
    (let* ((ncols (length names))
           (raw (coerce (loop repeat ncols collect (make-array nrows :initial-element :null))
                        'simple-vector)))
      (loop for obj in objects
            for r from 0
            do (dolist (pair (json-object-pairs obj))
                 (let ((col (gethash (if schema (ascii-downcase (car pair)) (car pair)) index)))
                   (unless col
                     (ingest-error "key ~S is not part of the explicit schema" (car pair)))
                   (json-value-kind (cdr pair)) ; rejects nested values
                   (setf (svref (svref raw col) r) (cdr pair)))))
      (let ((defs (if schema
                      (mapcar (lambda (c) (make-column-def (column-def-name c) (column-def-type c))) schema)
                      (loop for name in names
                            for col across raw
                            collect (make-column-def name (infer-json-column-type col))))))
        (values defs
                (loop for def in defs
                      for col across raw
                      collect (let ((type (column-def-type def))
                                    (out (make-array nrows)))
                                (dotimes (r nrows out)
                                  (setf (svref out r)
                                        (if schema
                                            (convert-json-explicit (svref col r) type (1+ r)
                                                                   (column-def-name def))
                                            (convert-json-inferred (svref col r) type))))))
                nrows)))))
