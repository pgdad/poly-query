;;;; common.lisp — shared ingestion machinery: options, limits, column naming,
;;;; text type inference and typed column construction.

(in-package #:polyquery)

(defconstant +max-field-bytes+ (* 16 1024 1024))

(defstruct ingest-spec
  "Everything a parser needs to turn input into a table."
  (table-name "" :type string)
  (format :csv)
  (schema nil)                    ; list of COLUMN-DEF or NIL (infer)
  (header t)
  (delimiter #\,)
  (max-rows 200000000))

(defun check-column-names (names)
  "Reject empty and (case-insensitively) duplicated column names."
  (let ((seen (make-hash-table :test 'equal)))
    (dolist (n names)
      (when (zerop (length n))
        (ingest-error "empty column name"))
      (let ((k (ascii-downcase n)))
        (when (gethash k seen)
          (ingest-error "duplicate column name ~S" n))
        (setf (gethash k seen) t)))))

(defun check-row-limit (count spec)
  (when (> count (ingest-spec-max-rows spec))
    (resource-limit-error "table exceeds the maximum of ~D rows" (ingest-spec-max-rows spec))))

;;; ------------------------------------------------------------------
;;; Text inference (ingestion.md §1.1). Candidate types are tracked as a bit mask.

(defconstant +cand-boolean+ 1)
(defconstant +cand-int64+ 2)
(defconstant +cand-float64+ 4)
(defconstant +cand-date+ 8)
(defconstant +cand-timestamp+ 16)
(defconstant +cand-all+ 31)

(defun text-candidates (s mask)
  "Restrict MASK to the inferable types that the trimmed text S matches."
  (let ((result 0))
    (when (and (logtest mask +cand-boolean+) (eq (nth-value 1 (text-to-boolean s)) :ok))
      (setf result (logior result +cand-boolean+)))
    (when (logtest mask (logior +cand-int64+ +cand-float64+))
      (when (and (logtest mask +cand-int64+) (eq (nth-value 1 (text-to-int64 s)) :ok))
        (setf result (logior result +cand-int64+)))
      (when (and (logtest mask +cand-float64+) (eq (nth-value 1 (text-to-float64 s)) :ok))
        (setf result (logior result +cand-float64+))))
    (when (logtest mask (logior +cand-date+ +cand-timestamp+))
      (let ((date (parse-date-text s)))
        (cond (date
               (setf result (logior result (logand mask (logior +cand-date+ +cand-timestamp+)))))
              ((and (logtest mask +cand-timestamp+) (parse-timestamp-text s))
               (setf result (logior result +cand-timestamp+))))))
    result))

(defun candidates-to-type (mask)
  (cond ((logtest mask +cand-boolean+) :boolean)
        ((logtest mask +cand-int64+) :int64)
        ((logtest mask +cand-float64+) :float64)
        ((logtest mask +cand-date+) :date)
        ((logtest mask +cand-timestamp+) :timestamp)
        (t :string)))

(defun infer-text-column-type (texts)
  "Infer the type of a column from its non-null trimmed texts (a sequence)."
  (let ((mask +cand-all+) (any nil))
    (map nil (lambda (s)
               (when (and (stringp s) (plusp mask))
                 (setf any t)
                 (setf mask (text-candidates (trim-spaces-tabs s) mask))))
         texts)
    (if any (candidates-to-type mask) :string)))
