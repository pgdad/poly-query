;;;; limits.lisp — statement size limits (change request CR-6,
;;;; spec/changes/expression-limits.md).
;;;;
;;;; The parser measures every statement while it reads it: the text length
;;;; in UTF-8 bytes, the nesting depth (each enclosing construct adds one
;;;; level; a chain of binary operators of one precedence level adds one
;;;; level whatever its length) and the operand count (literals, column
;;;; references and `*`). A statement beyond a limit fails with
;;;; RESOURCE_LIMIT naming the measure, before anything else is done with it.
;;;; Later stages process expression trees recursively; the limits bound
;;;; their depth, and the threads are sized for it (see CALL-WITH-STACK-GUARD).

(in-package #:polyquery)

(defparameter *max-statement-bytes* (* 16 1024 1024)
  "Largest SQL text of one statement, in UTF-8 bytes (minimum: 1 MiB).")

(defparameter *max-nesting-depth* 4096
  "Largest nesting depth of one statement (minimum: 1,000).")

(defparameter *max-operands* 250000
  "Largest number of operands (literals, column references and `*`) of one
statement (minimum: 25,000).")

(defun utf-8-length (string)
  "Number of bytes of STRING encoded as UTF-8."
  (let ((n 0))
    (declare (type fixnum n))
    (loop for c across string
          for code = (char-code c)
          do (incf n (cond ((< code #x80) 1)
                           ((< code #x800) 2)
                           ((< code #x10000) 3)
                           (t 4))))
    n))

(defun check-statement-length (sql)
  "Signal RESOURCE_LIMIT when the text SQL exceeds *MAX-STATEMENT-BYTES*."
  ;; Every character takes at least one byte: only long texts need counting.
  (when (> (length sql) (floor *max-statement-bytes* 4))
    (let ((bytes (utf-8-length sql)))
      (when (> bytes *max-statement-bytes*)
        (resource-limit-error "statement text length of ~D bytes exceeds ~D"
                              bytes *max-statement-bytes*)))))

(defun nesting-depth-error ()
  (resource-limit-error "expression nesting depth exceeds ~D" *max-nesting-depth*))

(defun operand-count-error ()
  (resource-limit-error "operand count exceeds ~D" *max-operands*))
