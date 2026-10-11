;;;; vexpressions.lisp — compiles bound expressions into vector kernels.
;;;;
;;;; A kernel is a function (batch) -> VEC computing an expression for every
;;;; row of a batch. Common operators have typed kernels that run one tight
;;;; loop per batch over (SIGNED-BYTE 64) / DOUBLE-FLOAT data (comparisons,
;;;; arithmetic, boolean logic, NULL tests, promotions). Every other operator
;;;; is *lifted*: its arguments are evaluated as vectors and the operator's
;;;; row implementation (expressions.lisp) is applied per element, so both
;;;; executors share one definition of every function's semantics.
;;;;
;;;; Evaluation is as lazy as the row evaluator's where that can matter, i.e.
;;;; where an operand may signal an error (MAY-FAIL-P): an operand is only
;;;; evaluated on the rows where the row evaluator would evaluate it (after
;;;; a non-NULL left operand of a strict operator, a non-FALSE left operand of
;;;; AND, a non-TRUE one of OR, the rows reaching a CASE branch). Operands
;;;; that cannot fail are evaluated on the whole batch.

(in-package #:polyquery)

;;; ------------------------------------------------------------------
;;; Failure analysis

(defun safe-cast-p (from to)
  (or (type-equal from to)
      (null-type-p from)
      (and (member (type-kind from) '(:int64 :decimal)) (eq (type-kind to) :float64))))

(defun mixes-int-and-decimal-p (exprs)
  "True if EXPRS include both INT64 and DECIMAL operands (their comparison
promotes the INT64 operand, which can overflow; types.md §2)."
  (let ((kinds (mapcar (lambda (e) (type-kind (bexpr-type e))) exprs)))
    (and (member :int64 kinds) (member :decimal kinds))))

(defun node-may-fail-p (e)
  (and (b-op-p e)
       (case (b-op-op e)
         ((:+ :- :* :/ :% :neg :call :subquery) t)
         (:cast (not (safe-cast-p (bexpr-type (first (b-op-args e))) (bexpr-type e))))
         ((:= :<> :< :<= :> :>= :between :in-list :case) (mixes-int-and-decimal-p (b-op-args e)))
         (t nil))))

(defun may-fail-p (e)
  "True if evaluating E can signal an error for some row."
  (bexpr-some #'node-may-fail-p e))

;;; ------------------------------------------------------------------
;;; Evaluation on a subset of the rows

(defun sub-batch (batch idx m refs)
  "Batch of the rows IDX[0..M) of BATCH holding only the columns REFS."
  (let* ((columns (batch-columns batch))
         (out (make-array (length columns) :initial-element nil)))
    (dolist (k refs)
      (setf (svref out k) (vec-gather (svref columns k) idx m)))
    (make-batch m out)))

(defun eval-subset (kernel refs batch idx m)
  "Value VEC (M rows, aligned with IDX) of KERNEL on the rows IDX[0..M) of BATCH."
  (declare (type function kernel) (type fixnum m))
  (if (= m (batch-count batch))
      (funcall kernel batch)
      (funcall kernel (sub-batch batch idx m refs))))

(defun eval-on-rows (kernel refs kind batch idx m)
  "Value VEC (all rows of BATCH) of KERNEL evaluated only on the rows
IDX[0..M); the other rows are NULL."
  (let ((n (batch-count batch)))
    (cond ((= m n) (funcall kernel batch))
          ((zerop m) (null-vec kind n))
          (t (vec-scatter (funcall kernel (sub-batch batch idx m refs)) idx m n kind)))))

(defun non-null-indices (vec idx m)
  "(values indices count) of the rows among IDX[0..M) (all rows if IDX is
NIL) where VEC is not NULL."
  (declare (type fixnum m))
  (let ((out (make-index-vector m))
        (count 0))
    (declare (type fixnum count))
    (dotimes (k m)
      (let ((i (if idx (aref (the index-vector idx) k) k)))
        (unless (eq (vec-ref vec i) +null+)
          (setf (aref out count) i)
          (incf count))))
    (values out count)))

(defstruct (operand (:constructor make-operand (kernel refs kind may-fail)))
  "A compiled argument: its kernel, the columns it reads, its vector kind and
whether it can fail."
  kernel refs kind may-fail)

(defun compile-operand (e)
  (make-operand (compile-vexpr e) (bexpr-column-indexes e) (type-vec-kind (bexpr-type e))
                (may-fail-p e)))

(defun make-arguments-evaluator (operands strict)
  "Function (batch) -> SIMPLE-VECTOR of the operand VECs. With STRICT, an
operand that may fail is only evaluated on rows where all earlier operands
are non-NULL (the other rows get NULL), as in the row evaluator."
  (let* ((operands (coerce operands 'simple-vector))
         (m (length operands))
         (later-may-fail (make-array m :initial-element nil)))
    (loop for k from (- m 2) downto 0
          do (setf (svref later-may-fail k)
                   (or (svref later-may-fail (1+ k))
                       (operand-may-fail (svref operands (1+ k))))))
    (lambda (batch)
      (let ((vecs (make-array m))
            (n (batch-count batch))
            (live nil) (live-count 0))
        (declare (type fixnum n live-count))
        (dotimes (k m vecs)
          (let* ((op (svref operands k))
                 (vec (if (and strict live (operand-may-fail op))
                          (eval-on-rows (operand-kernel op) (operand-refs op) (operand-kind op)
                                        batch live live-count)
                          (funcall (the function (operand-kernel op)) batch))))
            (setf (svref vecs k) vec)
            (when (and strict (svref later-may-fail k)
                       (vec-has-nulls-p vec n))
              (multiple-value-setq (live live-count)
                (non-null-indices vec live (if live live-count n))))))))))

;;; ------------------------------------------------------------------
;;; Entry point

(defun compile-vexpr (e)
  "Kernel computing the bound expression E for every row of a batch."
  (etypecase e
    (b-literal (let ((v (b-literal-value e))
                     (kind (type-vec-kind (bexpr-type e))))
                 (lambda (batch) (constant-vec kind v (batch-count batch)))))
    (b-column (let ((i (b-column-index e)))
                (declare (type fixnum i))
                (lambda (batch) (svref (batch-columns batch) i))))
    (b-param (let ((env (b-param-env e))
                   (i (b-param-index e))
                   (kind (type-vec-kind (bexpr-type e))))
               (lambda (batch)
                 (constant-vec kind (svref (param-env-values env) i) (batch-count batch)))))
    (b-op (compile-vop e))
    (b-agg (error "internal: aggregate call outside an aggregation context"))))

(defun compile-vop (e)
  (let ((op (b-op-op e))
        (args (b-op-args e)))
    (ecase op
      ((:= :<> :< :<= :> :>=) (or (compile-vcompare e) (compile-lifted e :strict)))
      ((:+ :- :* :/ :%) (or (compile-varithmetic e) (compile-lifted e :strict)))
      (:neg (or (compile-vnegation e) (compile-lifted e :strict)))
      (:and (compile-vlogic e :and))
      (:or (compile-vlogic e :or))
      (:not (compile-vnot e))
      ((:is-null :is-not-null) (compile-vnull-test e))
      (:cast (or (compile-vcast e) (compile-lifted e :strict)))
      ((:concat :like) (compile-lifted e :strict))
      (:between (compile-lifted e :eager))
      (:in-list (if (every #'bexpr-constant-p (rest args))
                    (compile-lifted e :eager)
                    (compile-row-fallback e)))
      (:case (compile-vcase e))
      (:call (compile-lifted e (if (or (scalar-function-null-aware (b-op-info e))
                                       (> (length args) 2))
                                   :eager
                                   :strict)))
      (:subquery (compile-lifted e :eager)))))

;;; ------------------------------------------------------------------
;;; Generic paths

(defun compile-lifted (e mode)
  "Kernel for E evaluating its non-constant arguments as vectors (MODE
:STRICT or :EAGER, see MAKE-ARGUMENTS-EVALUATOR) and applying E's row
implementation to every row of argument values."
  (let* ((args (b-op-args e))
         (lifted (remove-if #'bexpr-constant-p args))
         (operands (mapcar #'compile-operand lifted))
         (slot -1)
         (synthetic (make-b-op (bexpr-type e) (b-op-op e)
                               (mapcar (lambda (a)
                                         (if (bexpr-constant-p a)
                                             a
                                             (make-b-column (bexpr-type a) (incf slot) nil)))
                                       args)
                               (b-op-info e)))
         (fn (compile-bexpr synthetic))
         (m (length lifted))
         (kind (type-vec-kind (bexpr-type e)))
         (evaluate (make-arguments-evaluator operands (eq mode :strict))))
    (declare (type function fn evaluate) (type fixnum m))
    (lambda (batch)
      (let ((vecs (funcall evaluate batch))
            (row (make-array m)))
        (declare (type simple-vector vecs))
        (build-vec kind (batch-count batch)
                   (lambda (i)
                     (dotimes (k m)
                       (setf (svref row k) (vec-ref (svref vecs k) i)))
                     (funcall fn row)))))))

(defun compile-row-fallback (e)
  "Kernel applying the row implementation of the whole expression E row by row."
  (let ((fn (compile-bexpr e))
        (refs (bexpr-column-indexes e))
        (kind (type-vec-kind (bexpr-type e))))
    (declare (type function fn))
    (lambda (batch)
      (let* ((columns (batch-columns batch))
             (row (make-array (length columns) :initial-element +null+)))
        (build-vec kind (batch-count batch)
                   (lambda (i)
                     (dolist (k refs)
                       (setf (svref row k) (vec-ref (svref columns k) i)))
                     (funcall fn row)))))))

;;; ------------------------------------------------------------------
;;; Typed loops

(defmacro do-valid-rows ((i n validity) valid-form &optional (null-form nil))
  "Loop I over [0, N), running VALID-FORM for non-NULL rows and NULL-FORM
for rows whose bit in VALIDITY is 0."
  `(if ,validity
       (dotimes (,i ,n)
         (if (zerop (sbit ,validity ,i)) ,null-form ,valid-form))
       (dotimes (,i ,n) ,valid-form)))

(defmacro binary-kernel ((evaluate x-type y-type) out-type expr)
  "Kernel over two typed operand vectors X, Y (via EVALUATE) computing EXPR
(in terms of A and B) into a vector of OUT-TYPE (:I64 :F64 or :BOOLEAN)."
  `(lambda (batch)
     (let* ((n (batch-count batch))
            (vecs (funcall (the function ,evaluate) batch))
            (va (svref vecs 0)) (vb (svref vecs 1))
            (x (vec-data va)) (y (vec-data vb))
            (validity (and-validity (vec-validity va) (vec-validity vb))))
       (declare (type fixnum n) (type ,x-type x) (type ,y-type y)
                (type (or null simple-bit-vector) validity))
       ,(ecase out-type
          (:boolean
           `(let ((out (make-array n)))
              (do-valid-rows (i n validity)
                (setf (svref out i) (let ((a (aref x i)) (b (aref y i))) ,expr))
                (setf (svref out i) +null+))
              (make-vec out)))
          (:i64
           `(let ((out (make-array n :element-type '(signed-byte 64) :initial-element 0)))
              (do-valid-rows (i n validity)
                (setf (aref out i) (let ((a (aref x i)) (b (aref y i))) ,expr)))
              (make-vec out validity)))
          (:f64
           `(let ((out (make-array n :element-type 'double-float :initial-element 0d0)))
              (do-valid-rows (i n validity)
                (setf (aref out i) (let ((a (aref x i)) (b (aref y i))) ,expr)))
              (make-vec out validity)))))))

(defmacro constant-kernel ((kernel x-type constant) out-type expr)
  "Kernel over one typed operand vector X (from KERNEL) and the constant B."
  `(let ((b ,constant))
     (lambda (batch)
       (let* ((n (batch-count batch))
              (va (funcall (the function ,kernel) batch))
              (x (vec-data va))
              (validity (vec-validity va)))
         (declare (type fixnum n) (type ,x-type x) (type (or null simple-bit-vector) validity))
         ,(ecase out-type
            (:boolean
             `(let ((out (make-array n)))
                (do-valid-rows (i n validity)
                  (setf (svref out i) (let ((a (aref x i))) ,expr))
                  (setf (svref out i) +null+))
                (make-vec out))))))))

;;; ------------------------------------------------------------------
;;; Comparisons

(defun constant-operand-value (e)
  "(values value ok) of a constant operand that can be evaluated now."
  (if (and (bexpr-constant-p e) (not (may-fail-p e)))
      (values (evaluate-constant e) t)
      (values nil nil)))

(defun normalized-constant (e normalizer)
  "The constant operand E mapped by NORMALIZER, or (values nil nil) if E is
not constant or the normalization fails (the row evaluator then reports
the error at the right time)."
  (multiple-value-bind (v ok) (constant-operand-value e)
    (cond ((not ok) (values nil nil))
          ((eq v +null+) (values v t))
          (t (handler-case (values (funcall (the function normalizer) v) t)
               (pq-error () (values nil nil)))))))

(defmacro comparison-dispatch (op macro &rest macro-args)
  "Expand MACRO for the comparison operator OP with the test form bound."
  `(ecase ,op
     (:= (,macro ,@macro-args (= a b)))
     (:<> (,macro ,@macro-args (/= a b)))
     (:< (,macro ,@macro-args (< a b)))
     (:<= (,macro ,@macro-args (<= a b)))
     (:> (,macro ,@macro-args (> a b)))
     (:>= (,macro ,@macro-args (>= a b)))))

(defmacro typed-compare-vv (evaluate type test)
  `(binary-kernel (,evaluate (simple-array ,type (*)) (simple-array ,type (*))) :boolean ,test))

(defmacro typed-compare-vc (kernel type constant test)
  `(constant-kernel (,kernel (simple-array ,type (*)) ,constant) :boolean ,test))

(defun flip-comparison-op (op)
  (ecase op (:= :=) (:<> :<>) (:< :>) (:<= :>=) (:> :<) (:>= :<=)))

(defun compile-vcompare (e)
  "Typed comparison kernel, or NIL when the operand types need the generic path."
  (destructuring-bind (a b) (b-op-args e)
    (let ((op (b-op-op e))
          (lt (bexpr-type a)) (rt (bexpr-type b)))
      (multiple-value-bind (nl nr) (comparison-normalizers lt rt)
        (let ((ka (type-vec-kind lt)) (kb (type-vec-kind rt)))
          (cond
            ;; column op constant (either order); the constant is normalized once.
            ((and (bexpr-constant-p b) (not (bexpr-constant-p a)) (eq nl #'identity))
             (compile-vcompare-constant op a (type-vec-kind lt) b nr))
            ((and (bexpr-constant-p a) (not (bexpr-constant-p b)) (eq nr #'identity))
             (compile-vcompare-constant (flip-comparison-op op) b (type-vec-kind rt) a nl))
            ((not (and (eq nl #'identity) (eq nr #'identity))) nil)
            ((and (eq ka :i64) (eq kb :i64))
             (let ((evaluate (make-arguments-evaluator (list (compile-operand a) (compile-operand b)) t)))
               (comparison-dispatch op typed-compare-vv evaluate (signed-byte 64))))
            ((and (eq ka :f64) (eq kb :f64))
             (let ((evaluate (make-arguments-evaluator (list (compile-operand a) (compile-operand b)) t)))
               (comparison-dispatch op typed-compare-vv evaluate double-float)))
            ((and (eq ka :any) (eq kb :any))
             (let ((evaluate (make-arguments-evaluator (list (compile-operand a) (compile-operand b)) t))
                   (cmp (make-value-comparator lt rt)))
               (declare (type function cmp))
               (macrolet ((generic (test)
                            `(binary-kernel (evaluate simple-vector simple-vector) :boolean
                                            (if (or (eq a +null+) (eq b +null+))
                                                +null+
                                                (let ((c (funcall cmp a b)))
                                                  (declare (type fixnum c))
                                                  (let ((a c) (b 0)) ,test))))))
                 (comparison-dispatch op generic))))
            (t nil)))))))

(defun compile-vcompare-constant (op column-expr kind constant-expr normalizer)
  "Kernel for COLUMN-EXPR op CONSTANT-EXPR, or NIL."
  (multiple-value-bind (c ok) (normalized-constant constant-expr normalizer)
    (cond
      ((not ok) nil)
      ((eq c +null+)
       (let ((kernel (compile-vexpr column-expr)))
         (declare (type function kernel))
         (lambda (batch)
           (funcall kernel batch)
           (constant-vec :any +null+ (batch-count batch)))))
      ((and (eq kind :i64) (integerp c) (typep c '(signed-byte 64)))
       (let ((kernel (compile-vexpr column-expr)))
         (comparison-dispatch op typed-compare-vc kernel (signed-byte 64) c)))
      ((and (eq kind :f64) (typep c 'double-float))
       (let ((kernel (compile-vexpr column-expr)))
         (comparison-dispatch op typed-compare-vc kernel double-float c)))
      ((and (eq kind :any) (stringp c) (member op '(:= :<>)))
       (let ((kernel (compile-vexpr column-expr))
             (want (eq op :=)))
         (declare (type function kernel) (type string c))
         (lambda (batch)
           (let* ((n (batch-count batch))
                  (x (vec-data (funcall kernel batch)))
                  (out (make-array n)))
             (declare (type simple-vector x))
             (dotimes (i n)
               (let ((v (svref x i)))
                 (setf (svref out i)
                       (if (eq v +null+)
                           +null+
                           (if (string= (the string v) c) want (not want))))))
             (make-vec out)))))
      (t nil))))

;;; ------------------------------------------------------------------
;;; Arithmetic

(defun compile-varithmetic (e)
  "Typed arithmetic kernel, or NIL."
  (destructuring-bind (a b) (b-op-args e)
    (let* ((op (b-op-op e))
           (rk (type-kind (bexpr-type e)))
           (ak (type-kind (bexpr-type a)))
           (bk (type-kind (bexpr-type b)))
           (evaluate (when (and (eq rk ak) (eq rk bk)
                                (or (eq rk :int64)
                                    (and (eq rk :float64) (not (eq op :%)))
                                    (and (eq rk :decimal) (member op '(:+ :- :*)))))
                       (make-arguments-evaluator (list (compile-operand a) (compile-operand b)) t))))
      (macrolet ((i64 (expr) `(binary-kernel (evaluate i64-vector i64-vector) :i64 ,expr))
                 (f64 (expr) `(binary-kernel (evaluate f64-vector f64-vector) :f64 ,expr)))
        (cond
          ((null evaluate) nil)
          ((eq rk :int64)
           (ecase op
             (:+ (i64 (check-int64 (+ a b))))
             (:- (i64 (check-int64 (- a b))))
             (:* (i64 (check-int64 (* a b))))
             (:/ (i64 (int64-divide a b)))
             (:% (i64 (int64-remainder a b)))))
          ((eq rk :float64)
           (ecase op
             (:+ (f64 (check-finite (+ a b))))
             (:- (f64 (check-finite (- a b))))
             (:* (f64 (check-finite (* a b))))
             (:/ (f64 (float-divide a b)))))
          ((eq rk :decimal)
           (let* ((ls (decimal-scale (bexpr-type a)))
                  (rs (decimal-scale (bexpr-type b)))
                  (scale (max ls rs))
                  (lf (pow10 (- scale ls)))
                  (rf (pow10 (- scale rs)))
                  (limit (pow10 +max-decimal-precision+)))
             (declare (type (signed-byte 64) lf rf limit))
             (flet ((fit (v)
                      (if (< (- limit) v limit)
                          v
                          (overflow-error "DECIMAL result exceeds 18 digits"))))
               (declare (inline fit))
               (ecase op
                 (:+ (i64 (fit (+ (* a lf) (* b rf)))))
                 (:- (i64 (fit (- (* a lf) (* b rf)))))
                 (:* (i64 (fit (* a b))))))))
          (t nil))))))

(defun compile-vnegation (e)
  (let* ((a (first (b-op-args e)))
         (kernel (compile-vexpr a)))
    (declare (type function kernel))
    (macrolet ((unary (element-type expr)
                 `(lambda (batch)
                    (let* ((n (batch-count batch))
                           (va (funcall kernel batch))
                           (x (vec-data va))
                           (validity (vec-validity va))
                           (out (make-array n :element-type ',element-type
                                              :initial-element (coerce 0 ',element-type))))
                      (declare (type (simple-array ,element-type (*)) x))
                      (do-valid-rows (i n validity)
                        (setf (aref out i) (let ((a (aref x i))) ,expr)))
                      (make-vec out validity)))))
      (case (type-kind (bexpr-type e))
        (:int64 (and (eq (type-kind (bexpr-type a)) :int64)
                     (unary (signed-byte 64) (check-int64 (- a)))))
        (:decimal (and (eq (type-kind (bexpr-type a)) :decimal)
                       (unary (signed-byte 64) (- a))))
        (:float64 (and (eq (type-kind (bexpr-type a)) :float64)
                       (unary double-float (- a))))
        (t nil)))))

;;; ------------------------------------------------------------------
;;; Promotions

(defun compile-vcast (e)
  "Typed kernel for the numeric promotions the binder inserts, or NIL."
  (let* ((a (first (b-op-args e)))
         (from (bexpr-type a))
         (to (bexpr-type e))
         (kernel (compile-vexpr a)))
    (declare (type function kernel))
    (cond
      ((type-equal from to) kernel)
      ((and (eq (type-kind from) :int64) (eq (type-kind to) :float64))
       (lambda (batch)
         (let* ((n (batch-count batch))
                (va (funcall kernel batch))
                (x (vec-data va))
                (out (make-array n :element-type 'double-float :initial-element 0d0)))
           (declare (type i64-vector x))
           (dotimes (i n) (setf (aref out i) (coerce (aref x i) 'double-float)))
           (make-vec out (vec-validity va)))))
      ((and (member (type-kind from) '(:int64 :decimal)) (eq (type-kind to) :decimal)
            (>= (decimal-scale to) (if (decimal-type-p from) (decimal-scale from) 0)))
       ;; Exact rescaling; values needing more than 18 digits overflow.
       (let* ((factor (pow10 (- (decimal-scale to) (if (decimal-type-p from) (decimal-scale from) 0))))
              (limit (pow10 (decimal-precision to))))
         (declare (type (signed-byte 64) factor limit))
         (lambda (batch)
           (let* ((n (batch-count batch))
                  (va (funcall kernel batch))
                  (x (vec-data va))
                  (validity (vec-validity va))
                  (out (make-array n :element-type '(signed-byte 64) :initial-element 0)))
             (declare (type i64-vector x))
             (do-valid-rows (i n validity)
               (let ((v (* (aref x i) factor)))
                 (if (< (- limit) v limit)
                     (setf (aref out i) v)
                     (overflow-error "value does not fit ~A" (type-name-string to)))))
             (make-vec out validity)))))
      (t nil))))

;;; ------------------------------------------------------------------
;;; Boolean logic (three-valued) and NULL tests

(defun compile-vlogic (e which)
  "AND / OR. The right operand is evaluated lazily when it may fail: AND
only where the left one is not FALSE, OR only where it is not TRUE."
  (destructuring-bind (a b) (b-op-args e)
    (let ((ka (compile-vexpr a))
          (kb (compile-vexpr b))
          (refs (bexpr-column-indexes b))
          (lazy (may-fail-p b)))
      (declare (type function ka kb))
      (lambda (batch)
        (let* ((n (batch-count batch))
               (x (vec-data (funcall ka batch)))
               (y (vec-data
                   (if lazy
                       (let ((idx (make-index-vector n)) (m 0))
                         (declare (type fixnum m) (type simple-vector x))
                         (dotimes (i n)
                           (unless (eq (svref x i) (if (eq which :and) nil t))
                             (setf (aref idx m) i)
                             (incf m)))
                         (eval-on-rows kb refs :any batch idx m))
                       (funcall kb batch))))
               (out (make-array n)))
          (declare (type simple-vector x y))
          (if (eq which :and)
              (dotimes (i n)
                (setf (svref out i)
                      (let ((p (svref x i)))
                        (if (null p)
                            nil
                            (let ((q (svref y i)))
                              (cond ((null q) nil)
                                    ((or (eq p +null+) (eq q +null+)) +null+)
                                    (t t)))))))
              (dotimes (i n)
                (setf (svref out i)
                      (let ((p (svref x i)))
                        (if (eq p t)
                            t
                            (let ((q (svref y i)))
                              (cond ((eq q t) t)
                                    ((or (eq p +null+) (eq q +null+)) +null+)
                                    (t nil))))))))
          (make-vec out))))))

(defun compile-vnot (e)
  (let ((kernel (compile-vexpr (first (b-op-args e)))))
    (declare (type function kernel))
    (lambda (batch)
      (let* ((n (batch-count batch))
             (x (vec-data (funcall kernel batch)))
             (out (make-array n)))
        (declare (type simple-vector x))
        (dotimes (i n)
          (let ((v (svref x i)))
            (setf (svref out i) (if (eq v +null+) +null+ (not v)))))
        (make-vec out)))))

(defun compile-vnull-test (e)
  (let ((kernel (compile-vexpr (first (b-op-args e))))
        (want-null (eq (b-op-op e) :is-null)))
    (declare (type function kernel))
    (lambda (batch)
      (let* ((n (batch-count batch))
             (vec (funcall kernel batch))
             (data (vec-data vec))
             (validity (vec-validity vec))
             (out (make-array n)))
        (if (simple-vector-p data)
            (dotimes (i n)
              (setf (svref out i) (eq (eq (svref data i) +null+) want-null)))
            (dotimes (i n)
              (setf (svref out i)
                    (eq (and validity (zerop (sbit validity i)) t) want-null))))
        (make-vec out)))))

;;; ------------------------------------------------------------------
;;; CASE: each branch is evaluated only on the rows that reach it.

(defun compile-vcase (e)
  (destructuring-bind (simple-p else-p) (b-op-info e)
    (let* ((args (b-op-args e))
           (operand (when simple-p (first args)))
           (pairs (if simple-p (rest args) args))
           (n-when (floor (- (length pairs) (if else-p 1 0)) 2))
           (whens (loop for k below n-when collect (compile-operand (nth (* 2 k) pairs))))
           (thens (loop for k below n-when collect (compile-operand (nth (1+ (* 2 k)) pairs))))
           (else (when else-p (compile-operand (car (last pairs)))))
           (operand-kernel (when simple-p (compile-vexpr operand)))
           (tests (when simple-p
                    (loop for k below n-when
                          collect (make-equality-test (bexpr-type operand)
                                                      (bexpr-type (nth (* 2 k) pairs))))))
           (kind (type-vec-kind (bexpr-type e))))
      (flet ((eval-op (op batch idx m)
               (eval-subset (operand-kernel op) (operand-refs op) batch idx m)))
        (lambda (batch)
          (let* ((n (batch-count batch))
                 (out (make-array n :initial-element +null+))
                 (remaining (identity-index-vector n))
                 (rcount n)
                 (operand-vec (when operand-kernel (funcall (the function operand-kernel) batch)))
                 (unmatched-null-operand '()))
            (declare (type fixnum rcount))
            (when operand-vec
              ;; Rows with a NULL operand match no WHEN.
              (multiple-value-bind (idx m) (non-null-indices operand-vec nil n)
                (dotimes (i n)
                  (when (eq (vec-ref operand-vec i) +null+) (push i unmatched-null-operand)))
                (setf remaining idx rcount m)))
            (loop for w in whens
                  for th in thens
                  for k from 0
                  while (plusp rcount)
                  do (let ((cond-vec (eval-op w batch remaining rcount))
                           (hits (make-index-vector rcount)) (h 0)
                           (rest (make-index-vector rcount)) (r 0))
                       (declare (type fixnum h r))
                       (dotimes (j rcount)
                         (let* ((row (aref remaining j))
                                (c (vec-ref cond-vec j))
                                (hit (if operand-vec
                                         (and (not (eq c +null+))
                                              (funcall (the function (nth k tests))
                                                       (vec-ref operand-vec row) c))
                                         (eq c t))))
                           (if hit
                               (progn (setf (aref hits h) row) (incf h))
                               (progn (setf (aref rest r) row) (incf r)))))
                       (when (plusp h)
                         (let ((values (eval-op th batch hits h)))
                           (dotimes (j h)
                             (setf (svref out (aref hits j)) (vec-ref values j)))))
                       (setf remaining rest rcount r)))
            (when else
              (let* ((extra (length unmatched-null-operand))
                     (idx (make-index-vector (+ rcount extra)))
                     (m 0))
                (declare (type fixnum m))
                (dotimes (j rcount) (setf (aref idx m) (aref remaining j)) (incf m))
                (dolist (row unmatched-null-operand) (setf (aref idx m) row) (incf m))
                (when (plusp m)
                  (let ((values (eval-op else batch (sort idx #'<) m)))
                    (dotimes (j m)
                      (setf (svref out (aref idx j)) (vec-ref values j)))))))
            (vec-from-values kind out n)))))))
