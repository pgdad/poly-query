;;;; functions.lisp — scalar function registry (functions.md §1).
;;;;
;;;; Each function has an arity range, a typing function (argument types ->
;;;; result type, signalling TYPE_ERROR) and an implementation builder
;;;; (argument types -> function of the evaluated argument values). Unless a
;;;; function is marked :NULL-AWARE, a NULL argument yields NULL without
;;;; calling the implementation.

(in-package #:polyquery)

(defstruct scalar-function
  name
  (min-args 0) (max-args 0)
  typer                                  ; (arg-types) -> result type
  builder                                ; (arg-types) -> (lambda (&rest values))
  (null-aware nil)
  (test-only nil))

(defvar *scalar-functions* (make-hash-table :test 'equal))

(defmacro define-scalar-function (name (&key (min 0) (max min) null-aware test-only)
                                  &key typer builder)
  `(setf (gethash ,name *scalar-functions*)
         (make-scalar-function :name ,name :min-args ,min :max-args ,max
                               :null-aware ,null-aware :test-only ,test-only
                               :typer ,typer :builder ,builder)))

(defparameter *aggregate-function-names* '("COUNT" "SUM" "AVG" "MIN" "MAX"))

(defparameter *unimplemented-function-names*
  '("ABS" "ROUND" "FLOOR" "CEIL" "CEILING" "SQRT" "POWER" "MOD" "LENGTH" "UPPER" "LOWER"
    "SUBSTR" "SUBSTRING" "TRIM" "LTRIM" "RTRIM" "REPLACE" "CONCAT" "COALESCE" "NULLIF"
    "YEAR" "MONTH" "DAY" "HOUR" "MINUTE" "SECOND" "DATE_TRUNC" "DATE_DIFF")
  "Functions of the specification that this engine does not implement yet;
calling them answers UNSUPPORTED rather than an unknown-function error.")

(defun find-scalar-function (name test-functions-enabled)
  "Look up the function NAME (case-insensitive). Signals SEMANTIC_ERROR for
unknown names and UNSUPPORTED for specified-but-unimplemented ones."
  (let* ((key (ascii-upcase name))
         (fn (gethash key *scalar-functions*)))
    (cond ((and fn (or (not (scalar-function-test-only fn)) test-functions-enabled)) fn)
          ((member key *unimplemented-function-names* :test #'string=)
           (unsupported-error "function ~A is not supported" key))
          (t (semantic-error "unknown function ~A" name)))))

(defun check-arg-type (fname type predicate description)
  (unless (or (null-type-p type) (funcall predicate type))
    (type-error* "~A expects ~A, got ~A" fname description (type-name-string type))))

;;; ------------------------------------------------------------------
;;; Test functions

(defun sleep-with-interrupts (ms)
  "Sleep MS milliseconds in short slices so timeouts/cancellation are observed."
  (let ((end (+ (get-internal-real-time)
                (floor (* ms internal-time-units-per-second) 1000))))
    (loop
      (check-interrupts)
      (let ((remaining (- end (get-internal-real-time))))
        (when (<= remaining 0) (return))
        (sleep (min 0.005 (/ remaining internal-time-units-per-second)))))))

(define-scalar-function "PQ_SLEEP" (:min 1 :test-only t)
  :typer (lambda (types)
           (check-arg-type "PQ_SLEEP" (first types) (lambda (ty) (eq ty :int64)) "INT64")
           :int64)
  :builder (lambda (types)
             (declare (ignore types))
             (lambda (ms)
               (when (minusp ms)
                 (invalid-argument-error "PQ_SLEEP expects a non-negative duration"))
               (sleep-with-interrupts ms)
               ms)))
