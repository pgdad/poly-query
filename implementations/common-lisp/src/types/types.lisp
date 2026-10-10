;;;; types.lisp — SQL data types: representation, names, promotion rules.
;;;;
;;;; A type is a keyword (:BOOLEAN :INT64 :FLOAT64 :STRING :DATE :TIMESTAMP,
;;;; or :NULL for the type of a bare NULL literal) or a list
;;;; (:DECIMAL precision scale).
;;;;
;;;; Runtime values are untyped; the static type decides their meaning:
;;;;   NULL -> :NULL   BOOLEAN -> T / NIL   INT64 -> integer
;;;;   FLOAT64 -> double-float   DECIMAL(p,s) -> unscaled integer
;;;;   STRING -> string   DATE -> integer days since 1970-01-01
;;;;   TIMESTAMP -> integer microseconds since 1970-01-01 00:00:00

(in-package #:polyquery)

(defconstant +null+ :null)

(declaim (inline null-value-p))
(defun null-value-p (v) (eq v :null))

(defun make-decimal-type (precision scale)
  (list :decimal precision scale))

(declaim (inline type-kind))
(defun type-kind (type)
  (if (consp type) (first type) type))

(defun decimal-type-p (type) (and (consp type) (eq (first type) :decimal)))
(defun decimal-precision (type) (second type))
(defun decimal-scale (type) (third type))

(defun numeric-type-p (type)
  (member (type-kind type) '(:int64 :decimal :float64)))

(defun temporal-type-p (type)
  (member type '(:date :timestamp)))

(defun null-type-p (type) (eq type :null))

(defun type-equal (a b) (equal a b))

(defun type-name-string (type)
  "Canonical type name for result metadata. The null type reports as STRING."
  (ecase (type-kind type)
    (:boolean "BOOLEAN")
    (:int64 "INT64")
    (:float64 "FLOAT64")
    (:string "STRING")
    (:date "DATE")
    (:timestamp "TIMESTAMP")
    (:null "STRING")
    (:decimal (format nil "DECIMAL(~D,~D)" (decimal-precision type) (decimal-scale type)))))

(defun output-type (type)
  "The type actually used for a result column (null type becomes STRING)."
  (if (null-type-p type) :string type))

(defun resolve-type-name (name params error-code)
  "Resolve a type NAME (case-insensitive, aliases allowed) with a list of
integer PARAMS. Signals ERROR-CODE for unknown names or bad parameters."
  (let ((n (ascii-upcase name)))
    (flet ((no-params (type)
             (when params
               (signal-pq-error error-code "type ~A takes no parameters" name))
             type))
      (cond ((member n '("BOOLEAN" "BOOL") :test #'string=) (no-params :boolean))
            ((member n '("INT64" "INT" "INTEGER" "BIGINT") :test #'string=) (no-params :int64))
            ((member n '("FLOAT64" "DOUBLE" "FLOAT" "REAL") :test #'string=) (no-params :float64))
            ((member n '("STRING" "VARCHAR" "TEXT") :test #'string=) (no-params :string))
            ((string= n "DATE") (no-params :date))
            ((string= n "TIMESTAMP") (no-params :timestamp))
            ((member n '("DECIMAL" "NUMERIC") :test #'string=)
             (let ((p (if params (first params) 18))
                   (s (if (rest params) (second params) 0)))
               (when (or (> (length params) 2)
                         (not (integerp p)) (not (integerp s))
                         (< p 1) (> p +max-decimal-precision+) (< s 0) (> s p))
                 (signal-pq-error error-code "invalid DECIMAL parameters"))
               (make-decimal-type p s)))
            (t (signal-pq-error error-code "unknown type ~A" name))))))

(defun parse-type-string (text error-code)
  "Parse a type written as text, e.g. \"DECIMAL(10, 2)\" or \"bigint\"."
  (let* ((s (trim-whitespace text))
         (open (position #\( s)))
    (if (null open)
        (resolve-type-name s nil error-code)
        (let ((close (position #\) s :start open)))
          (unless (and close (= close (1- (length s))))
            (signal-pq-error error-code "malformed type ~S" text))
          (let ((params (loop for part in (split-string (subseq s (1+ open) close) #\,)
                              for v = (parse-int-text (trim-whitespace part))
                              unless (and v (>= v 0))
                                do (signal-pq-error error-code "malformed type ~S" text)
                              collect v)))
            (resolve-type-name (trim-whitespace (subseq s 0 open)) params error-code))))))

(defun split-string (s char)
  (loop with start = 0
        for pos = (position char s :start start)
        collect (subseq s start pos)
        while pos
        do (setf start (1+ pos))))

;;; ------------------------------------------------------------------
;;; Promotion

(defun common-numeric-type (a b)
  "Common numeric type of two numeric types (types.md §2)."
  (let ((ka (type-kind a)) (kb (type-kind b)))
    (cond ((or (eq ka :float64) (eq kb :float64)) :float64)
          ((and (eq ka :int64) (eq kb :int64)) :int64)
          (t (make-decimal-type +max-decimal-precision+
                                (max (if (eq ka :decimal) (decimal-scale a) 0)
                                     (if (eq kb :decimal) (decimal-scale b) 0)))))))

(defun comparison-type (a b)
  "The type both operands of a comparison are promoted to, or NIL when the two
types are not comparable. The null type is compatible with everything."
  (cond ((null-type-p a) b)
        ((null-type-p b) a)
        ((and (numeric-type-p a) (numeric-type-p b)) (common-numeric-type a b))
        ((and (temporal-type-p a) (temporal-type-p b))
         (if (and (eq a :date) (eq b :date)) :date :timestamp))
        ((eq (type-kind a) (type-kind b)) a)
        (t nil)))

(defun unify-result-types (types)
  "Common type of several branch results (CASE/COALESCE rules, semantics §13).
Returns NIL when they cannot be unified."
  (let ((result :null))
    (dolist (ty types result)
      (cond ((null-type-p ty))
            ((null-type-p result) (setf result ty))
            ((and (numeric-type-p result) (numeric-type-p ty))
             (unless (type-equal result ty)
               (setf result (common-numeric-type result ty))))
            ((type-equal result ty))
            (t (return nil))))))
