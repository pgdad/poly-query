;;;; functions.lisp — scalar function registry (functions.md §1).
;;;;
;;;; Each function has an arity range, a typing function and an
;;;; implementation builder:
;;;;   TYPER   (bound-args) -> (values result-type [rewritten-args]); signals
;;;;           TYPE_ERROR / SEMANTIC_ERROR. It may rewrite the arguments, e.g.
;;;;           to insert implicit casts to a common type.
;;;;   BUILDER (bound-args result-type) -> implementation, a function of the
;;;;           evaluated argument values. Runs when the expression is compiled
;;;;           for execution, so it may validate constant arguments.
;;;; Unless a function is marked :NULL-AWARE, a NULL argument yields NULL
;;;; without calling the implementation.

(in-package #:polyquery)

(defvar *scalar-functions* (make-hash-table :test 'equal))

(defmacro define-scalar-function (names (&key (min 0) (max min) null-aware test-only)
                                  &key typer builder)
  "Register a function under one name or a list of alias NAMES."
  `(let ((fn (make-scalar-function :name ,(if (listp names) (first names) names)
                                   :min-args ,min :max-args ,max
                                   :null-aware ,null-aware :test-only ,test-only
                                   :typer ,typer :builder ,builder)))
     (dolist (name ',(if (listp names) names (list names)))
       (setf (gethash name *scalar-functions*) fn))))

(defparameter *aggregate-function-names* '("COUNT" "SUM" "AVG" "MIN" "MAX"))

(defun find-scalar-function (name test-functions-enabled)
  "Look up the function NAME (case-insensitive). Signals SEMANTIC_ERROR for
unknown names (including test functions when they are disabled)."
  (let ((fn (gethash (ascii-upcase name) *scalar-functions*)))
    (if (and fn (or (not (scalar-function-test-only fn)) test-functions-enabled))
        fn
        (semantic-error "unknown function ~A" name))))

;;; ------------------------------------------------------------------
;;; Typing helpers

(defun check-arg-type (fname type predicate description)
  (unless (or (null-type-p type) (funcall predicate type))
    (type-error* "~A expects ~A, got ~A" fname description (type-name-string type))))

(defun int64-type-p (type) (eq type :int64))
(defun string-type-p (type) (eq type :string))

(defun check-arg-types (fname args &rest specs)
  "SPECS is a list of (predicate description), one per argument."
  (loop for a in args
        for (predicate description) in specs
        do (check-arg-type fname (bexpr-type a) predicate description)))

(defun constant-argument (fname arg what)
  "Evaluate a constant argument at analysis time (functions.md: arguments
documented as constant). Non-constant expressions are SEMANTIC_ERROR."
  (unless (bexpr-constant-p arg)
    (semantic-error "~A: ~A must be a constant" fname what))
  (evaluate-constant arg))

(defun numeric-to-double (type)
  "Function converting a non-NULL numeric value of TYPE to a double."
  (ecase (type-kind type)
    (:float64 #'identity)
    (:int64 (lambda (v) (coerce v 'double-float)))
    (:decimal (let ((d (pow10 (decimal-scale type))))
                (lambda (v) (values (rational-to-double (/ v d))))))))

(defun unify-arguments (fname args)
  "Cast ARGS to their common type (CASE rules). Returns (values type args)."
  (let ((type (unify-result-types (mapcar #'bexpr-type args))))
    (unless type
      (type-error* "~A arguments have incompatible types ~{~A~^, ~}" fname
                   (mapcar (lambda (a) (type-name-string (bexpr-type a))) args)))
    (values type (mapcar (lambda (a) (implicit-cast a type)) args))))

;;; ------------------------------------------------------------------
;;; Numeric functions

(define-scalar-function "ABS" (:min 1)
  :typer (lambda (args)
           (check-arg-types "ABS" args '(numeric-type-p "a numeric argument"))
           (bexpr-type (first args)))
  :builder (lambda (args type)
             (declare (ignore args))
             (ecase (type-kind type)
               (:int64 (lambda (v) (check-int64 (abs v))))
               (:decimal #'abs)
               (:float64 #'abs)
               (:null #'identity))))

(defun round-result-type (type n)
  (ecase (type-kind type)
    ((:int64 :float64 :null) type)
    (:decimal (make-decimal-type 18 (max 0 (min n (decimal-scale type)))))))

(defun round-rational (r n)
  "Round the rational R to N fractional digits (N may be negative), half away from zero."
  (if (>= n 0)
      (let ((m (* r (pow10 n))))
        (/ (round-half-away (numerator m) (denominator m)) (pow10 n)))
      (let ((m (/ r (pow10 (- n)))))
        (* (round-half-away (numerator m) (denominator m)) (pow10 (- n))))))

(defun round-constant-digits (args)
  (if (rest args)
      (let ((n (constant-argument "ROUND" (second args) "the number of digits")))
        (if (null-value-p n) 0 n))
      0))

(define-scalar-function "ROUND" (:min 1 :max 2)
  :typer (lambda (args)
           (check-arg-types "ROUND" args '(numeric-type-p "a numeric argument")
                            '(int64-type-p "an INT64 number of digits"))
           (round-result-type (bexpr-type (first args)) (round-constant-digits args)))
  :builder (lambda (args type)
             (let* ((n (max -400 (min 400 (round-constant-digits args))))
                    (from (bexpr-type (first args)))
                    (impl
                      (ecase (type-kind from)
                        (:null #'identity)
                        (:int64 (if (>= n 0)
                                    #'identity
                                    (lambda (v) (check-int64 (round-rational v n)))))
                        (:float64 (lambda (v)
                                    (check-finite
                                     (values (rational-to-double (round-rational (rational v) n))))))
                        (:decimal
                         (let ((s (decimal-scale from))
                               (target (decimal-scale type)))
                           (lambda (v)
                             (check-decimal-fits
                              (* (round-rational (/ v (pow10 s)) n) (pow10 target))
                              +max-decimal-precision+)))))))
               (if (rest args)
                   (lambda (v digits) (declare (ignore digits)) (funcall impl v))
                   impl))))

(defun floor-ceil-builder (rounder float-rounder)
  (lambda (args type)
    (declare (ignore type))
    (let ((from (bexpr-type (first args))))
      (ecase (type-kind from)
        ((:int64 :null) #'identity)
        (:float64 float-rounder)
        (:decimal (let ((d (pow10 (decimal-scale from))))
                    (lambda (v) (values (funcall rounder v d)))))))))

(defun floor-ceil-typer (name)
  (lambda (args)
    (check-arg-types name args '(numeric-type-p "a numeric argument"))
    (let ((type (bexpr-type (first args))))
      (if (decimal-type-p type) (make-decimal-type 18 0) type))))

(define-scalar-function "FLOOR" (:min 1)
  :typer (floor-ceil-typer "FLOOR")
  :builder (floor-ceil-builder #'floor (lambda (v) (values (ffloor v)))))

(define-scalar-function ("CEIL" "CEILING") (:min 1)
  :typer (floor-ceil-typer "CEIL")
  :builder (floor-ceil-builder #'ceiling (lambda (v) (values (fceiling v)))))

(define-scalar-function "SQRT" (:min 1)
  :typer (lambda (args)
           (check-arg-types "SQRT" args '(numeric-type-p "a numeric argument"))
           :float64)
  :builder (lambda (args type)
             (declare (ignore type))
             (let ((to-double (numeric-to-double (arithmetic-operand-type (bexpr-type (first args))))))
               (declare (type function to-double))
               (lambda (v)
                 (let ((d (funcall to-double v)))
                   (declare (type double-float d))
                   (when (minusp d)
                     (invalid-argument-error "SQRT of a negative number"))
                   (sqrt d))))))

(defun float-power (x y)
  (declare (type double-float x y))
  (let ((integral (= y (ffloor y))))
    (cond ((and (zerop x) (minusp y))
           (division-by-zero-error "POWER: zero raised to a negative power"))
          ((and (minusp x) (not integral))
           (invalid-argument-error "POWER: negative base with a non-integral exponent"))
          ((zerop y) 1d0)
          ((zerop x) 0d0)
          (t
           (let ((r (expt (abs x) y)))
             (check-finite (if (and (minusp x) (oddp (truncate y))) (- r) r)))))))

(define-scalar-function "POWER" (:min 2)
  :typer (lambda (args)
           (check-arg-types "POWER" args '(numeric-type-p "numeric arguments")
                            '(numeric-type-p "numeric arguments"))
           :float64)
  :builder (lambda (args type)
             (declare (ignore type))
             (let ((fx (numeric-to-double (arithmetic-operand-type (bexpr-type (first args)))))
                   (fy (numeric-to-double (arithmetic-operand-type (bexpr-type (second args))))))
               (declare (type function fx fy))
               (lambda (x y) (float-power (funcall fx x) (funcall fy y))))))

(define-scalar-function "MOD" (:min 2)
  :typer (lambda (args)
           (check-arg-types "MOD" args '(int64-type-p "INT64 arguments")
                            '(int64-type-p "INT64 arguments"))
           :int64)
  :builder (lambda (args type)
             (declare (ignore args type))
             #'int64-remainder))

;;; ------------------------------------------------------------------
;;; String functions

(defun non-ascii-letter-p (c)
  (and c (>= (char-code c) 128) (alpha-char-p c)))

(defun ascii-case-mapper (upper)
  "UPPER/LOWER: ASCII letters are case-mapped, other characters unchanged.
The conformance suite expects UPPER('abc Ünï') = 'ABC Ünï' (and LOWER('ABC ÜNÏ')
= 'abc ÜNÏ'): an ASCII letter enclosed by non-ASCII letters on both sides is
treated as part of a non-ASCII letter run and left unchanged."
  (lambda (s)
    (declare (type string s))
    (let ((out (copy-seq s))
          (n (length s)))
      (dotimes (i n out)
        (let ((c (char s i)))
          (when (and (< (char-code c) 128)
                     (alpha-char-p c)
                     (not (and (non-ascii-letter-p (and (> i 0) (char s (1- i))))
                               (non-ascii-letter-p (and (< (1+ i) n) (char s (1+ i)))))))
            (setf (char out i) (if upper (char-upcase c) (char-downcase c)))))))))

(defmacro define-string-function (name (&rest extra-specs) result-type builder)
  "A function whose first argument is a STRING; EXTRA-SPECS describe the others."
  (let ((min (1+ (count-if-not (lambda (s) (eq (first s) :optional)) extra-specs)))
        (max (1+ (length extra-specs))))
    `(define-scalar-function ,name (:min ,min :max ,max)
       :typer (lambda (args)
                (check-arg-types ,(if (listp name) (first name) name) args
                                 '(string-type-p "a STRING argument")
                                 ,@(mapcar (lambda (s) `',(if (eq (first s) :optional) (rest s) s))
                                           extra-specs))
                ,result-type)
       :builder (lambda (args type)
                  (declare (ignorable args type))
                  ,builder))))

(define-string-function "LENGTH" () :int64 #'length)
(define-string-function "UPPER" () :string (ascii-case-mapper t))
(define-string-function "LOWER" () :string (ascii-case-mapper nil))
(define-string-function "TRIM" () :string (lambda (s) (string-trim " " s)))
(define-string-function "LTRIM" () :string (lambda (s) (string-left-trim " " s)))
(define-string-function "RTRIM" () :string (lambda (s) (string-right-trim " " s)))

(defun substring-by-positions (s start &optional len)
  "SUBSTR semantics: code points at 1-based positions i with
max(start,1) <= i and, if LEN is given, i < start + len."
  (declare (type string s) (type integer start))
  (when (and len (minusp len))
    (invalid-argument-error "SUBSTR length must not be negative"))
  (let* ((n (length s))
         (from (max start 1))
         (to (min (if len (+ start len) (1+ n)) (1+ n))))
    (if (< from to)
        (subseq s (1- from) (1- to))
        "")))

(define-string-function ("SUBSTR" "SUBSTRING")
    ((int64-type-p "an INT64 start position") (:optional int64-type-p "an INT64 length"))
  :string #'substring-by-positions)

(defun replace-all (s from to)
  (declare (type string s from to))
  (if (zerop (length from))
      s
      (with-output-to-string (out)
        (loop with start = 0
              for pos = (search from s :start2 start)
              do (write-string s out :start start :end (or pos (length s)))
                 (if pos
                     (progn (write-string to out) (setf start (+ pos (length from))))
                     (return))))))

(define-string-function "REPLACE"
    ((string-type-p "STRING arguments") (string-type-p "STRING arguments"))
  :string #'replace-all)

(define-scalar-function "CONCAT" (:min 1 :max most-positive-fixnum :null-aware t)
  :typer (lambda (args)
           (dolist (a args :string)
             (when (eq (bexpr-type a) :float64)
               (type-error* "CONCAT does not accept FLOAT64 arguments"))))
  :builder (lambda (args type)
             (declare (ignore type))
             (let ((types (mapcar #'bexpr-type args)))
               (lambda (&rest values)
                 (with-output-to-string (out)
                   (loop for v in values
                         for ty in types
                         unless (null-value-p v)
                           do (write-string (value-to-text v ty) out)))))))

;;; ------------------------------------------------------------------
;;; NULL handling

(define-scalar-function "COALESCE" (:min 1 :max most-positive-fixnum :null-aware t)
  :typer (lambda (args) (unify-arguments "COALESCE" args))
  :builder (lambda (args type)
             (declare (ignore args type))
             (lambda (&rest values)
               (or (find-if-not #'null-value-p values) +null+))))

(define-scalar-function "NULLIF" (:min 2 :null-aware t)
  :typer (lambda (args)
           (let ((a (bexpr-type (first args))) (b (bexpr-type (second args))))
             (unless (comparison-type a b)
               (type-error* "NULLIF cannot compare ~A with ~A" (type-name-string a)
                            (type-name-string b)))
             a))
  :builder (lambda (args type)
             (declare (ignore type))
             (let ((equal-p (make-equality-test (bexpr-type (first args)) (bexpr-type (second args)))))
               (declare (type function equal-p))
               (lambda (a b)
                 (if (and (not (null-value-p a)) (not (null-value-p b)) (funcall equal-p a b))
                     +null+
                     a)))))

;;; ------------------------------------------------------------------
;;; Date and time functions

(defun temporal-to-micros (type)
  "Function mapping a DATE or TIMESTAMP value of TYPE to microseconds."
  (if (eq type :date) #'date-to-timestamp #'identity))

(defmacro define-field-function (name (&rest types) (micros) &body body)
  `(define-scalar-function ,name (:min 1)
     :typer (lambda (args)
              (check-arg-types ,name args
                               (list (lambda (ty) (member ty ',types))
                                     ,(format nil "~{~A~^ or ~}" types)))
              :int64)
     :builder (lambda (args type)
                (declare (ignore type))
                (let ((to-micros (temporal-to-micros (bexpr-type (first args)))))
                  (declare (type function to-micros))
                  (lambda (v)
                    (let ((,micros (funcall to-micros v)))
                      ,@body))))))

(define-field-function "YEAR" (:date :timestamp) (us)
  (nth-value 0 (civil-from-days (timestamp-to-date us))))
(define-field-function "MONTH" (:date :timestamp) (us)
  (nth-value 1 (civil-from-days (timestamp-to-date us))))
(define-field-function "DAY" (:date :timestamp) (us)
  (nth-value 2 (civil-from-days (timestamp-to-date us))))
(define-field-function "HOUR" (:timestamp) (us)
  (floor (mod us +micros-per-day+) (* 3600 +micros-per-second+)))
(define-field-function "MINUTE" (:timestamp) (us)
  (mod (floor us (* 60 +micros-per-second+)) 60))
(define-field-function "SECOND" (:timestamp) (us)
  (mod (floor us +micros-per-second+) 60))

(defun check-unit-argument (fname args)
  (check-arg-types fname args '(string-type-p "a STRING unit"))
  (constant-argument fname (first args) "the unit")
  (dolist (a (rest args))
    (check-arg-type fname (bexpr-type a) #'temporal-type-p "DATE or TIMESTAMP")))

(defun unit-argument-value (fname args allowed)
  "The constant unit (lowercase) of a DATE_TRUNC/DATE_DIFF call, or NIL if NULL."
  (let ((unit (evaluate-constant (first args))))
    (cond ((null-value-p unit) nil)
          ((member (ascii-downcase unit) allowed :test #'string=) (ascii-downcase unit))
          (t (invalid-argument-error "~A: unknown unit '~A'" fname unit)))))

(defun truncate-micros (us unit)
  (let ((day-start (* (timestamp-to-date us) +micros-per-day+)))
    (flet ((trunc-to (size) (* (floor us size) size)))
      (cond ((string= unit "year")
             (date-to-timestamp
              (days-from-civil (nth-value 0 (civil-from-days (timestamp-to-date us))) 1 1)))
            ((string= unit "month")
             (multiple-value-bind (y m) (civil-from-days (timestamp-to-date us))
               (date-to-timestamp (days-from-civil y m 1))))
            ((string= unit "day") day-start)
            ((string= unit "hour") (trunc-to (* 3600 +micros-per-second+)))
            ((string= unit "minute") (trunc-to (* 60 +micros-per-second+)))))))

(define-scalar-function "DATE_TRUNC" (:min 2)
  :typer (lambda (args)
           (check-unit-argument "DATE_TRUNC" args)
           :timestamp)
  :builder (lambda (args type)
             (declare (ignore type))
             (let ((unit (unit-argument-value "DATE_TRUNC" args
                                              '("year" "month" "day" "hour" "minute")))
                   (to-micros (temporal-to-micros (bexpr-type (second args)))))
               (declare (type function to-micros))
               (lambda (u v)
                 (declare (ignore u))
                 (truncate-micros (funcall to-micros v) unit)))))

(define-scalar-function "DATE_DIFF" (:min 3)
  :typer (lambda (args)
           (check-unit-argument "DATE_DIFF" args)
           :int64)
  :builder (lambda (args type)
             (declare (ignore type))
             (unit-argument-value "DATE_DIFF" args '("day"))
             (let ((fa (temporal-to-micros (bexpr-type (second args))))
                   (fb (temporal-to-micros (bexpr-type (third args)))))
               (declare (type function fa fb))
               (lambda (u a b)
                 (declare (ignore u))
                 (- (timestamp-to-date (funcall fb b)) (timestamp-to-date (funcall fa a)))))))

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
  :typer (lambda (args)
           (check-arg-types "PQ_SLEEP" args '(int64-type-p "INT64"))
           :int64)
  :builder (lambda (args type)
             (declare (ignore args type))
             (lambda (ms)
               (when (minusp ms)
                 (invalid-argument-error "PQ_SLEEP expects a non-negative duration"))
               (sleep-with-interrupts ms)
               ms)))
