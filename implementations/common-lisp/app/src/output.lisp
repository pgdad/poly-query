;;;; output.lisp — printing results as table, csv or json (pqledger.md §7).

(in-package #:pqledger)

(defstruct (report (:constructor make-report (names types rows)))
  "A printable result: column NAMES, canonical type names TYPES and ROWS (a
vector of row vectors of native values as returned by the embedding API)."
  names types rows)

(defun report-from-result (result)
  (make-report (pq:result-column-names result) (pq:result-column-types result)
               (pq:result-rows result)))

(defun type-class (type)
  "The kind of the canonical type name TYPE as a keyword."
  (cond ((string= type "INT64") :int64)
        ((string= type "FLOAT64") :float64)
        ((string= type "STRING") :string)
        ((string= type "BOOLEAN") :boolean)
        ((string= type "DATE") :date)
        ((string= type "TIMESTAMP") :timestamp)
        ((starts-with-p "DECIMAL" type) :decimal)
        (t :string)))

(defun numeric-type-p (type)
  (member (type-class type) '(:int64 :decimal :float64)))

(defun format-fixed-6 (value)
  "The double VALUE as C's printf(\"%.6f\") prints it; -0.000000 is 0.000000."
  (let ((micros (round (* (rational value) 1000000))))
    (multiple-value-bind (whole fraction) (floor (abs micros) 1000000)
      (format nil "~:[~;-~]~D.~6,'0D" (minusp micros) whole fraction))))

(defun value-text (value type)
  "The value text of §7 (NIL for NULL)."
  (if (pq:null-value-p value)
      nil
      (ecase (type-class type)
        (:string value)
        (:int64 (format nil "~D" value))
        (:decimal (pq:decimal-string value (pq:decimal-type-scale type)))
        (:float64 (format-fixed-6 value))
        (:boolean (if value "true" "false"))
        (:date (pq:date-string value))
        (:timestamp (pq:timestamp-string value)))))

(defun row-texts (report)
  "The value texts of REPORT's rows: a list of lists of strings or NIL (NULL)."
  (loop with types = (report-types report)
        for row across (report-rows report)
        collect (loop for type in types
                      for k from 0
                      collect (value-text (svref row k) type))))

;;; ------------------------------------------------------------------
;;; table

(defun write-table (report out)
  (let* ((names (report-names report))
         (right (mapcar #'numeric-type-p (report-types report)))
         (rows (row-texts report))
         (widths (loop for name in names
                       for k from 0
                       collect (reduce #'max rows :key (lambda (row) (length (or (nth k row) "")))
                                                  :initial-value (length name)))))
    (flet ((line (cells)
             (let ((text (with-output-to-string (s)
                           (loop for cell in cells
                                 for width in widths
                                 for right-p in right
                                 for first = t then nil
                                 do (unless first (write-string "  " s))
                                    (let ((pad (- width (length cell))))
                                      (if right-p
                                          (progn (dotimes (i pad) (write-char #\Space s))
                                                 (write-string cell s))
                                          (progn (write-string cell s)
                                                 (dotimes (i pad) (write-char #\Space s)))))))))
               (write-line (string-right-trim " " text) out))))
      (line names)
      (line (mapcar (lambda (w) (make-string w :initial-element #\-)) widths))
      (dolist (row rows)
        (line (mapcar (lambda (cell) (or cell "")) row)))
      (format out "(~D row~:P)~%" (length rows)))))

;;; ------------------------------------------------------------------
;;; csv

(defun csv-field (text)
  "TEXT (NIL for NULL) as a CSV field."
  (cond ((null text) "")
        ((or (zerop (length text))
             (find-if (lambda (c) (member c '(#\, #\" #\Return #\Newline))) text)
             (char= (char text 0) #\Space)
             (char= (char text (1- (length text))) #\Space))
         (with-output-to-string (s)
           (write-char #\" s)
           (loop for c across text
                 do (when (char= c #\") (write-char #\" s))
                    (write-char c s))
           (write-char #\" s)))
        (t text)))

(defun write-csv (report out)
  (flet ((record (fields)
           (loop for field in fields
                 for first = t then nil
                 do (unless first (write-char #\, out))
                    (write-string field out))
           (write-char #\Newline out)))
    (record (mapcar #'csv-field (report-names report)))
    (dolist (row (row-texts report))
      (record (mapcar #'csv-field row)))))

;;; ------------------------------------------------------------------
;;; json

(defun write-json-string (text out)
  (write-char #\" out)
  (loop for c across text
        for code = (char-code c)
        do (case c
             (#\" (write-string "\\\"" out))
             (#\\ (write-string "\\\\" out))
             (t (cond ((= code 8) (write-string "\\b" out))
                      ((= code 9) (write-string "\\t" out))
                      ((= code 10) (write-string "\\n" out))
                      ((= code 12) (write-string "\\f" out))
                      ((= code 13) (write-string "\\r" out))
                      ((< code 32) (format out "\\u~(~4,'0x~)" code))
                      (t (write-char c out))))))
  (write-char #\" out))

(defun write-json (report out)
  (let ((names (report-names report))
        (classes (mapcar #'type-class (report-types report))))
    (dolist (row (row-texts report))
      (write-char #\{ out)
      (loop for name in names
            for class in classes
            for text in row
            for first = t then nil
            do (unless first (write-char #\, out))
               (write-json-string name out)
               (write-char #\: out)
               (cond ((null text) (write-string "null" out))
                     ((member class '(:int64 :float64 :boolean)) (write-string text out))
                     (t (write-json-string text out))))
      (write-char #\} out)
      (write-char #\Newline out))))

(defun write-report (report format out)
  "Print REPORT to the stream OUT in FORMAT (:TABLE, :CSV or :JSON)."
  (ecase format
    (:table (write-table report out))
    (:csv (write-csv report out))
    (:json (write-json report out))))
