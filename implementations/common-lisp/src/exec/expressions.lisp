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
    (b-param (let ((env (b-param-env e))
                   (i (b-param-index e)))
               (declare (type fixnum i))
               (lambda (row)
                 (declare (ignore row))
                 (svref (param-env-values env) i))))
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
                  (lambda (row) (null-value-p (funcall (the function f) row)))))
      (:is-not-null (let ((f (first fns)))
                      (lambda (row) (not (null-value-p (funcall (the function f) row))))))
      (:cast (let ((f (first fns))
                   (cast (make-cast-function (bexpr-type (first args)) (bexpr-type e))))
               (declare (type function cast))
               (if (null-type-p (bexpr-type (first args)))
                   (lambda (row) (declare (ignore row)) +null+)
                   (lambda (row) (with-non-null-args ((a f)) (funcall cast a))))))
      (:concat (let ((f (first fns)) (g (second fns)))
                 (lambda (row) (with-non-null-args ((a f) (b g)) (concatenate 'string a b)))))
      (:between (compile-between args fns))
      (:in-list (compile-in-list args fns))
      (:like (compile-like args fns))
      (:case (compile-case e fns))
      (:call (compile-call e fns))
      (:subquery (compile-subquery e fns)))))

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
                (rf (pow10 (- scale rs)))
                (precision (decimal-precision result-type))
                (limit (pow10 precision)))
           ;; Intermediates are exact (unbounded integers); only the result
           ;; is checked against the result precision W.
           (flet ((fit (v)
                    (if (< (- limit) v limit)
                        v
                        (overflow-error "DECIMAL result exceeds ~D digits" precision))))
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
values into a common representation and the type to compare them as.
INT64 and DECIMAL values compare exactly (decimal38.md §4): both sides are
rescaled to the larger scale without any range check; the kind is :INT64
when the normalized values are known to fit INT64, else a wide DECIMAL type
(values held as unbounded integers)."
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
                  (if (zerop shift)
                      #'identity
                      (let ((m (pow10 shift))) (lambda (v) (* v m)))))))))
      (cond
        ((numeric-type-p ct)
         (let ((nl (numeric-normalizer lt ct))
               (nr (numeric-normalizer rt ct)))
           (values nl nr
                   (cond ((eq (type-kind ct) :float64) :float64)
                         ((and (eq nl #'identity) (eq nr #'identity)
                               (not (wide-decimal-type-p lt)) (not (wide-decimal-type-p rt)))
                          :int64)
                         (t (make-decimal-type +max-decimal-precision+
                                               (if (decimal-type-p ct) (decimal-scale ct) 0)))))))
        ((eq ct :timestamp)
         (values (if (eq lt :date) #'date-to-timestamp #'identity)
                 (if (eq rt :date) #'date-to-timestamp #'identity)
                 :timestamp))
        (t (values #'identity #'identity ct))))))

(defun make-value-comparator (lt rt)
  "Function (a b) -> -1/0/1 comparing non-NULL values of types LT and RT."
  (multiple-value-bind (nl nr kind) (comparison-normalizers lt rt)
    (declare (type function nl nr))
    (let ((cmp (make-comparator kind)))
      (declare (type function cmp))
      (if (and (eq nl #'identity) (eq nr #'identity))
          cmp
          (lambda (a b) (funcall cmp (funcall nl a) (funcall nr b)))))))

(defun make-equality-test (lt rt)
  "Predicate (a b) on non-NULL values of types LT and RT: SQL equality."
  (let ((cmp (make-value-comparator lt rt)))
    (declare (type function cmp))
    (lambda (a b) (zerop (the fixnum (funcall cmp a b))))))

(defun comparison-result (op c)
  (declare (type fixnum c))
  (ecase op
    (:= (= c 0)) (:<> (/= c 0)) (:< (< c 0)) (:<= (<= c 0)) (:> (> c 0)) (:>= (>= c 0))))

(defun compile-comparison (op args fns)
  (let ((f (first fns)) (g (second fns))
        (cmp (make-value-comparator (bexpr-type (first args)) (bexpr-type (second args)))))
    (declare (type function f g cmp))
    (macrolet ((compare (test)
                 `(lambda (row)
                    (with-non-null-args ((a f) (b g))
                      (let ((c (funcall cmp a b)))
                        (declare (type fixnum c))
                        ,test)))))
      (ecase op
        (:= (compare (= c 0)))
        (:<> (compare (/= c 0)))
        (:< (compare (< c 0)))
        (:<= (compare (<= c 0)))
        (:> (compare (> c 0)))
        (:>= (compare (>= c 0)))))))

(defun hash-key-normalizer (lt rt)
  "Function mapping a non-NULL value of type LT to a key such that values of
types LT and RT that compare equal have EQUAL keys (see HASH-KEY-NORMALIZER
called with the arguments swapped for the other side)."
  (multiple-value-bind (nl nr kind) (comparison-normalizers lt rt)
    (declare (ignore nr) (type function nl))
    (if (eq kind :float64)
        (lambda (v) (let ((d (funcall nl v))) (if (zerop d) 0d0 d)))
        nl)))

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
;;; BETWEEN, IN lists, LIKE, CASE (semantics.md §11-13)

(defun compile-between (args fns)
  (destructuring-bind (x low high) args
    (destructuring-bind (fx flow fhigh) fns
      (declare (type function fx flow fhigh))
      (let ((cmp-low (make-value-comparator (bexpr-type x) (bexpr-type low)))
            (cmp-high (make-value-comparator (bexpr-type x) (bexpr-type high))))
        (declare (type function cmp-low cmp-high))
        (lambda (row)
          (let* ((v (funcall fx row))
                 (lo (funcall flow row))
                 (hi (funcall fhigh row))
                 ;; x >= low AND x <= high, three-valued
                 (ge (if (or (null-value-p v) (null-value-p lo))
                         +null+
                         (>= (the fixnum (funcall cmp-low v lo)) 0)))
                 (le (if (or (null-value-p v) (null-value-p hi))
                         +null+
                         (<= (the fixnum (funcall cmp-high v hi)) 0))))
            (cond ((or (null ge) (null le)) nil)
                  ((or (null-value-p ge) (null-value-p le)) +null+)
                  (t t))))))))

(defun compile-in-list (args fns)
  "x IN (e1, ..., en): TRUE if some ei equals x, else NULL if x or some ei is
NULL, else FALSE. Constant lists sharing one comparison type use a hash set."
  (let* ((x (first args))
         (xt (bexpr-type x))
         (fx (first fns))
         (items (rest args))
         (typed (remove-if #'null-type-p items :key #'bexpr-type))
         (common (and typed (comparison-type xt (bexpr-type (first typed))))))
    (declare (type function fx))
    (if (and typed
             (every #'bexpr-constant-p items)
             (every (lambda (i) (type-equal (comparison-type xt (bexpr-type i)) common)) typed))
        (let ((set (make-hash-table :test 'equal))
              (has-null nil)
              (probe (hash-key-normalizer xt (bexpr-type (first typed)))))
          (declare (type function probe))
          (dolist (item items)
            (let ((v (evaluate-constant item)))
              (if (null-value-p v)
                  (setf has-null t)
                  (setf (gethash (funcall (the function (hash-key-normalizer (bexpr-type item) xt)) v)
                                 set)
                        t))))
          (lambda (row)
            (let ((v (funcall fx row)))
              (cond ((null-value-p v) +null+)
                    ((gethash (funcall probe v) set) t)
                    (has-null +null+)
                    (t nil)))))
        (let ((tests (mapcar (lambda (i) (make-equality-test xt (bexpr-type i))) items))
              (item-fns (rest fns)))
          (lambda (row)
            (let ((v (funcall fx row)))
              (if (null-value-p v)
                  +null+
                  (block probe
                    (let ((saw-null nil))
                      (loop for f in item-fns
                            for test in tests
                            do (let ((w (funcall (the function f) row)))
                                 (cond ((null-value-p w) (setf saw-null t))
                                       ((funcall (the function test) v w) (return-from probe t)))))
                      (if saw-null +null+ nil))))))))))

(defun like-match-p (s p)
  "Whole-string LIKE match: % any sequence, _ exactly one code point."
  (declare (type string s p))
  (let ((n (length s)) (m (length p))
        (si 0) (pi* 0) (star-p -1) (star-s 0))
    (declare (type fixnum n m si pi* star-p star-s))
    ;; Greedy matching with backtracking to the last %.
    (loop
      (cond ((< si n)
             (cond ((and (< pi* m) (char= (char p pi*) #\%))
                    (setf star-p pi* star-s si)
                    (incf pi*))
                   ((and (< pi* m) (or (char= (char p pi*) #\_) (char= (char p pi*) (char s si))))
                    (incf si) (incf pi*))
                   ((>= star-p 0)
                    (setf pi* (1+ star-p))
                    (incf star-s)
                    (setf si star-s))
                   (t (return nil))))
            (t
             (loop while (and (< pi* m) (char= (char p pi*) #\%)) do (incf pi*))
             (return (= pi* m)))))))

(defun compile-like (args fns)
  (destructuring-bind (fs fp) fns
    (declare (type function fs fp))
    (if (and (bexpr-constant-p (second args)))
        (let ((pattern (evaluate-constant (second args))))
          (if (null-value-p pattern)
              (lambda (row) (declare (ignore row)) +null+)
              (lambda (row) (with-non-null-args ((s fs)) (like-match-p s pattern)))))
        (lambda (row) (with-non-null-args ((s fs) (p fp)) (like-match-p s p))))))

(defun compile-case (e fns)
  "ARGS are (operand? cond1 result1 ... [else]); INFO is (simple-p else-p)."
  (destructuring-bind (simple-p else-p) (b-op-info e)
    (let* ((args (b-op-args e))
           (operand (when simple-p (first args)))
           (fx (when simple-p (first fns)))
           (pairs (if simple-p (rest fns) fns))
           (pair-args (if simple-p (rest args) args))
           (else-fn (when else-p (car (last fns))))
           (n (floor (- (length pairs) (if else-p 1 0)) 2))
           (conds (coerce (loop for k below n collect (nth (* 2 k) pairs)) 'simple-vector))
           (results (coerce (loop for k below n collect (nth (1+ (* 2 k)) pairs)) 'simple-vector))
           (tests (when simple-p
                    (coerce (loop for k below n
                                  collect (make-equality-test (bexpr-type operand)
                                                              (bexpr-type (nth (* 2 k) pair-args))))
                            'simple-vector))))
      (if simple-p
          (lambda (row)
            (let ((v (funcall (the function fx) row)))
              (dotimes (k n (if else-fn (funcall (the function else-fn) row) +null+))
                (unless (null-value-p v)
                  (let ((w (funcall (the function (svref conds k)) row)))
                    (when (and (not (null-value-p w)) (funcall (the function (svref tests k)) v w))
                      (return (funcall (the function (svref results k)) row))))))))
          (lambda (row)
            (dotimes (k n (if else-fn (funcall (the function else-fn) row) +null+))
              (when (eq (funcall (the function (svref conds k)) row) t)
                (return (funcall (the function (svref results k)) row)))))))))

;;; ------------------------------------------------------------------
;;; Function calls

(defun compile-call (e fns)
  (let* ((fn (b-op-info e))
         (impl (funcall (scalar-function-builder fn) (b-op-args e) (bexpr-type e))))
    (declare (type function impl))
    (if (scalar-function-null-aware fn)
        (lambda (row) (apply impl (mapcar (lambda (f) (funcall (the function f) row)) fns)))
        (case (length fns)
          (1 (let ((f (first fns)))
               (lambda (row) (with-non-null-args ((a f)) (funcall impl a)))))
          (2 (let ((f (first fns)) (g (second fns)))
               (lambda (row) (with-non-null-args ((a f) (b g)) (funcall impl a b)))))
          (t (lambda (row)
               (let ((values (mapcar (lambda (f) (funcall (the function f) row)) fns)))
                 (if (some #'null-value-p values)
                     +null+
                     (apply impl values)))))))))

;;; ------------------------------------------------------------------
;;; Subqueries (semantics.md §8)
;;;
;;; The subquery's physical plan is compiled once; each evaluation opens a
;;; fresh iterator. Uncorrelated subqueries are evaluated at most once per
;;; query; correlated ones once per distinct parameter tuple (memoized).

(defun subquery-scalar-result (open)
  (let* ((next (funcall (the function open)))
         (row (funcall (the function next))))
    (cond ((null row) +null+)
          ((funcall (the function next))
           (signal-pq-error "SUBQUERY_CARDINALITY" "scalar subquery returned more than one row"))
          (t (svref row 0)))))

(defun subquery-exists-result (open)
  (and (funcall (the function (funcall (the function open)))) t))

(defstruct (value-set (:constructor make-value-set ()))
  (table (make-hash-table :test 'equal))
  (has-null nil)
  (empty t))

(defun subquery-set-result (open key-fn)
  (let ((next (funcall (the function open)))
        (set (make-value-set)))
    (loop for row = (funcall (the function next))
          while row
          do (let ((v (svref row 0)))
               (setf (value-set-empty set) nil)
               (if (null-value-p v)
                   (setf (value-set-has-null set) t)
                   (setf (gethash (funcall (the function key-fn) v) (value-set-table set)) t))))
    set))

(defun value-set-membership (set probe-key)
  "Three-valued x IN S for a non-NULL x whose key is PROBE-KEY."
  (cond ((gethash probe-key (value-set-table set)) t)
        ((value-set-has-null set) +null+)
        (t nil)))

(defun compile-subquery (e fns)
  (let* ((sq (b-op-info e))
         (kind (subquery-kind sq))
         (open (let ((*parallel-disabled* t)) (compile-plan (subquery-plan sq))))
         (env (subquery-param-env sq))
         (param-fns (coerce (if (eq kind :in) (rest fns) fns) 'simple-vector))
         (nparams (length param-fns))
         (column-type (column-def-type (first (bound-query-columns (subquery-query sq)))))
         (operand-type (when (eq kind :in) (bexpr-type (first (b-op-args e)))))
         (compute
           (ecase kind
             (:scalar (lambda () (subquery-scalar-result open)))
             (:exists (lambda () (subquery-exists-result open)))
             (:in (let ((key-fn (hash-key-normalizer column-type operand-type)))
                    (lambda () (subquery-set-result open key-fn))))))
         (result-for
           (cond
             ((zerop nparams)
              ;; Uncorrelated: evaluate lazily, once per query (shared by
              ;; the parallel workers' copies of the plan).
              (if (subquery-cacheable sq)
                  (let ((done nil) (cached nil))
                    (lambda (row)
                      (declare (ignore row))
                      (unless done
                        (setf cached (query-shared-value sq compute) done t))
                      cached))
                  (lambda (row) (declare (ignore row)) (funcall (the function compute)))))
             (t
              (let ((memo (and (subquery-cacheable sq) (make-hash-table :test 'equal))))
                (lambda (row)
                  (let ((params (make-array nparams)))
                    (dotimes (k nparams)
                      (setf (svref params k) (funcall (the function (svref param-fns k)) row)))
                    (let ((key (and memo (coerce params 'list))))
                      (multiple-value-bind (value found) (if memo (gethash key memo) (values nil nil))
                        (if found
                            value
                            (let ((saved (param-env-values env)))
                              (setf (param-env-values env) params)
                              (let ((value (unwind-protect (funcall (the function compute))
                                             (setf (param-env-values env) saved))))
                                (when memo (setf (gethash key memo) value))
                                value))))))))))))
    (declare (type function result-for))
    (ecase kind
      ((:scalar :exists) result-for)
      (:in
       (let ((fx (first fns))
             (probe (hash-key-normalizer operand-type column-type)))
         (declare (type function fx probe))
         (lambda (row)
           (let ((x (funcall fx row)))
             (if (null-value-p x)
                 ;; NULL IN (empty) is FALSE; otherwise NULL.
                 (if (value-set-empty (funcall result-for row)) nil +null+)
                 (let ((set (funcall result-for row)))
                   (if (value-set-empty set)
                       nil
                       (value-set-membership set (funcall probe x))))))))))))
