;;;; expressions.lisp — compiles bound expressions into closures over rows.
;;;;
;;;; A compiled expression is a function of one argument, the input row (a
;;;; SIMPLE-VECTOR), returning the value. Type dispatch happens once, at
;;;; compile time, using the static types recorded by the binder.

(in-package #:polyquery)

(defun compile-bexpr (e)
  (etypecase e
    (b-literal (let ((v (b-literal-value e))) (lambda (row) (declare (ignore row)) v)))
    (b-column (let ((i (b-column-index e)))
                (declare (type fixnum i))
                (lambda (row) (svref row i))))
    (b-op (compile-op e))
    (b-agg (error "internal: aggregate call outside an aggregation context"))))

(defmacro with-non-null-args ((&rest bindings) &body body)
  "Evaluate each (var fn) binding against ROW; return NULL as soon as one is NULL."
  (if (null bindings)
      `(progn ,@body)
      (destructuring-bind ((var fn) &rest more) bindings
        `(let ((,var (funcall (the function ,fn) row)))
           (if (null-value-p ,var)
               +null+
               (with-non-null-args ,more ,@body))))))

(defun compile-op (e)
  (let* ((op (b-op-op e))
         (args (b-op-args e))
         (fns (mapcar #'compile-bexpr args)))
    (ecase op
      ((:+ :- :* :/ :%) (compile-arithmetic op (bexpr-type e) args fns))
      (:neg (compile-negation (bexpr-type e) (first fns)))
      ((:= :<> :< :<= :> :>=) (compile-comparison op args fns))
      (:and (compile-and (first fns) (second fns)))
      (:or (compile-or (first fns) (second fns)))
      (:not (let ((f (first fns)))
              (lambda (row) (with-non-null-args ((a f)) (not a)))))
      (:is-null (let ((f (first fns)))
                  (lambda (row) (null-value-p (funcall f row)))))
      (:is-not-null (let ((f (first fns)))
                      (lambda (row) (not (null-value-p (funcall f row))))))
      (:cast (let ((f (first fns))
                   (cast (make-cast-function (bexpr-type (first args)) (bexpr-type e))))
               (declare (type function cast))
               (if (null-type-p (bexpr-type (first args)))
                   (lambda (row) (declare (ignore row)) +null+)
                   (lambda (row) (with-non-null-args ((a f)) (funcall cast a))))))
      (:concat (let ((f (first fns)) (g (second fns)))
                 (lambda (row) (with-non-null-args ((a f) (b g)) (concatenate 'string a b)))))
      (:call (compile-call e fns)))))

;;; ------------------------------------------------------------------
;;; Arithmetic (types.md §4)

(defun int64-divide (a b)
  (when (zerop b) (division-by-zero-error "division by zero"))
  (check-int64 (truncate a b)))

(defun int64-remainder (a b)
  (when (zerop b) (division-by-zero-error "division by zero"))
  (rem a b))

(defun float-divide (a b)
  (declare (type double-float a b))
  (when (zerop b) (division-by-zero-error "division by zero"))
  (check-finite (/ a b)))

(defun compile-arithmetic (op result-type args fns)
  (let ((f (first fns)) (g (second fns)))
    (declare (type function f g))
    (macrolet ((binary (expr)
                 `(lambda (row) (with-non-null-args ((a f) (b g)) ,expr))))
      (ecase (type-kind result-type)
        (:int64
         (ecase op
           (:+ (binary (check-int64 (+ (the integer a) (the integer b)))))
           (:- (binary (check-int64 (- (the integer a) (the integer b)))))
           (:* (binary (check-int64 (* (the integer a) (the integer b)))))
           (:/ (binary (int64-divide a b)))
           (:% (binary (int64-remainder a b)))))
        (:float64
         (ecase op
           (:+ (binary (check-finite (+ (the double-float a) (the double-float b)))))
           (:- (binary (check-finite (- (the double-float a) (the double-float b)))))
           (:* (binary (check-finite (* (the double-float a) (the double-float b)))))
           (:/ (binary (float-divide a b)))))
        (:decimal
         (let* ((ls (decimal-scale (bexpr-type (first args))))
                (rs (decimal-scale (bexpr-type (second args))))
                (scale (max ls rs))
                (lf (pow10 (- scale ls)))
                (rf (pow10 (- scale rs))))
           (flet ((fit (v)
                    (if (fits-precision-p v +max-decimal-precision+)
                        v
                        (overflow-error "DECIMAL result exceeds 18 digits"))))
             (ecase op
               (:+ (binary (fit (+ (* a lf) (* b rf)))))
               (:- (binary (fit (- (* a lf) (* b rf)))))
               (:* (binary (fit (* a b))))))))))))

(defun compile-negation (type f)
  (declare (type function f))
  (ecase (type-kind type)
    (:int64 (lambda (row) (with-non-null-args ((a f)) (check-int64 (- a)))))
    (:decimal (lambda (row) (with-non-null-args ((a f)) (- a))))
    (:float64 (lambda (row) (with-non-null-args ((a f)) (- (the double-float a)))))))

;;; ------------------------------------------------------------------
;;; Comparison (types.md §5)

(defun comparison-normalizers (lt rt)
  "Return (values left-fn right-fn kind): functions mapping each operand's
values into a common representation and the type kind to compare as."
  (let ((ct (comparison-type lt rt)))
    (flet ((numeric-normalizer (type target)
             (ecase (type-kind target)
               (:float64
                (ecase (type-kind type)
                  (:float64 #'identity)
                  (:int64 (lambda (v) (coerce v 'double-float)))
                  (:decimal (let ((d (pow10 (decimal-scale type))))
                              (lambda (v) (values (rational-to-double (/ v d))))))
                  (:null #'identity)))
               ((:int64 :decimal)
                (let ((shift (- (if (decimal-type-p target) (decimal-scale target) 0)
                                (if (decimal-type-p type) (decimal-scale type) 0))))
                  (cond ((and (eq (type-kind type) :int64) (decimal-type-p target))
                         ;; INT64 -> DECIMAL(18,s) promotion overflows beyond 18 digits
                         ;; (types.md §2).
                         (let ((m (pow10 shift)))
                           (lambda (v) (check-decimal-fits (* v m) +max-decimal-precision+))))
                        ((zerop shift) #'identity)
                        (t (let ((m (pow10 shift))) (lambda (v) (* v m))))))))))
      (cond
        ((numeric-type-p ct)
         (values (numeric-normalizer lt ct) (numeric-normalizer rt ct)
                 (if (eq (type-kind ct) :float64) :float64 :int64)))
        ((eq ct :timestamp)
         (values (if (eq lt :date) #'date-to-timestamp #'identity)
                 (if (eq rt :date) #'date-to-timestamp #'identity)
                 :timestamp))
        (t (values #'identity #'identity ct))))))

(defun compile-comparison (op args fns)
  (let ((f (first fns)) (g (second fns)))
    (declare (type function f g))
    (multiple-value-bind (nl nr kind)
        (comparison-normalizers (bexpr-type (first args)) (bexpr-type (second args)))
      (declare (type function nl nr))
      (let ((cmp (make-comparator kind)))
        (declare (type function cmp))
        (macrolet ((compare (test)
                     `(lambda (row)
                        (with-non-null-args ((a f) (b g))
                          (let ((c (funcall cmp (funcall nl a) (funcall nr b))))
                            (declare (type fixnum c))
                            ,test)))))
          (ecase op
            (:= (compare (= c 0)))
            (:<> (compare (/= c 0)))
            (:< (compare (< c 0)))
            (:<= (compare (<= c 0)))
            (:> (compare (> c 0)))
            (:>= (compare (>= c 0)))))))))

;;; ------------------------------------------------------------------
;;; Three-valued logic (types.md §6)

(defun compile-and (f g)
  (declare (type function f g))
  (lambda (row)
    (let ((a (funcall f row)))
      (if (null a)
          nil
          (let ((b (funcall g row)))
            (cond ((null b) nil)
                  ((or (null-value-p a) (null-value-p b)) +null+)
                  (t t)))))))

(defun compile-or (f g)
  (declare (type function f g))
  (lambda (row)
    (let ((a (funcall f row)))
      (if (eq a t)
          t
          (let ((b (funcall g row)))
            (cond ((eq b t) t)
                  ((or (null-value-p a) (null-value-p b)) +null+)
                  (t nil)))))))

;;; ------------------------------------------------------------------
;;; Function calls

(defun compile-call (e fns)
  (let* ((fn (b-op-info e))
         (impl (funcall (scalar-function-builder fn) (mapcar #'bexpr-type (b-op-args e)))))
    (declare (type function impl))
    (if (scalar-function-null-aware fn)
        (lambda (row) (apply impl (mapcar (lambda (f) (funcall (the function f) row)) fns)))
        (case (length fns)
          (1 (let ((f (first fns)))
               (lambda (row) (with-non-null-args ((a f)) (funcall impl a)))))
          (t (lambda (row)
               (let ((values (mapcar (lambda (f) (funcall (the function f) row)) fns)))
                 (if (some #'null-value-p values)
                     +null+
                     (apply impl values)))))))))
