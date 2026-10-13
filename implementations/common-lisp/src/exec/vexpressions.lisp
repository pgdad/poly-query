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
;;; Evaluation on a subset of the rows

(defun sub-batch (batch idx m refs)
  "Batch of the rows IDX[0..M) of BATCH holding only the columns REFS."
  (let* ((columns (batch-columns batch))
         (out (make-array (length columns) :initial-element nil)))
    (dolist (k refs)
      (setf (svref out k) (vec-gather (svref columns k) idx m)))
    (make-batch m out)))

(defun eval-subset (kernel refs batch idx m)
  "Value VEC (M rows, aligned with IDX) of KERNEL on the rows IDX[0..M) of
BATCH. IDX must be ascending."
  (declare (type function kernel) (type fixnum m))
  (if (= m (batch-count batch))
      (funcall kernel batch)
      (funcall kernel (sub-batch batch idx m refs))))

(defun eval-on-rows (kernel refs kind batch idx m)
  "Value VEC (all rows of BATCH) of KERNEL evaluated only on the rows
IDX[0..M) (ascending); the other rows are NULL."
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
      ;; The result vector is allocated after the operands are evaluated: an
      ;; array allocated before a deep evaluation (a long operator chain) is
      ;; promoted by the collections during it and would then keep every
      ;; operand vector stored into it alive until an old generation is
      ;; collected.
      (let ((collected '())
            (n (batch-count batch))
            (live nil) (live-count 0))
        (declare (type fixnum n live-count))
        (dotimes (k m (coerce (nreverse collected) 'simple-vector))
          (let* ((op (svref operands k))
                 (vec (if (and strict live (operand-may-fail op))
                          (eval-on-rows (operand-kernel op) (operand-refs op) (operand-kind op)
                                        batch live live-count)
                          (funcall (the function (operand-kernel op)) batch))))
            (push vec collected)
            (when (and strict (svref later-may-fail k)
                       (vec-has-nulls-p vec n))
              (multiple-value-setq (live live-count)
                (non-null-indices vec live (if live live-count n))))))))))

;;; ------------------------------------------------------------------
;;; Entry point

(defconstant +batch-checkpoint-nodes+ 64
  "Expression nodes evaluated per batch between two deadline checks (see
INTERRUPT-CHECKPOINT-P).")

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
    (b-op (check-interrupts)            ; long statements: compiling takes time too
          (let ((kernel (compile-vop e)))
            (declare (type function kernel))
            (if (interrupt-checkpoint-p e +batch-checkpoint-nodes+)
                ;; Checked after the subtree: its work happens on the way back up.
                (lambda (batch) (prog1 (funcall kernel batch) (check-interrupts)))
                kernel)))
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
      (:concat (compile-lifted e :strict))
      (:like (or (compile-vlike e) (compile-lifted e :strict)))
      (:between (compile-lifted e :eager))
      (:in-list (if (every #'bexpr-constant-p (rest args))
                    (compile-lifted e :eager)
                    (compile-row-fallback e)))
      (:case (compile-vcase e))
      (:call (or (compile-vcall-of-string e)
                 (compile-lifted e (if (or (scalar-function-null-aware (b-op-info e))
                                           (> (length args) 2))
                                       :eager
                                       :strict))))
      (:subquery (compile-lifted e :eager)))))

;;; ------------------------------------------------------------------
;;; Generic paths

(defconstant +max-vector-operands+ 64
  "Operator arguments (CASE branches) evaluated as whole-batch vectors at
most; wider operators are evaluated row by row (or branch by branch), so
the vectors of one operator never hold more than a few MB (CR-6).")

(defun compile-lifted (e mode)
  "Kernel for E evaluating its non-constant arguments as vectors (MODE
:STRICT or :EAGER, see MAKE-ARGUMENTS-EVALUATOR) and applying E's row
implementation to every row of argument values. With more than
+MAX-VECTOR-OPERANDS+ such arguments (e.g. COALESCE of thousands of
columns) the row implementation runs on each row instead."
  (when (> (count-if-not #'bexpr-constant-p (b-op-args e)) +max-vector-operands+)
    (return-from compile-lifted (compile-row-fallback e)))
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
      ((and (eq kind :any) (member c '(t nil)) (eq (type-kind (bexpr-type column-expr)) :boolean))
       ;; BOOLEAN operand (T / NIL / NULL values): FALSE sorts before TRUE.
       (let ((kernel (compile-vexpr column-expr))
             (test (comparison-test op))
             (cv (if c 1 0)))
         (declare (type function kernel test) (type fixnum cv))
         (lambda (batch)
           (let* ((n (batch-count batch))
                  (data (vec-data (funcall kernel batch)))
                  (out (make-array n)))
             (declare (type simple-vector data out) (type fixnum n))
             (dotimes (i n (make-vec out))
               (let ((v (svref data i)))
                 (setf (svref out i)
                       (if (eq v +null+) +null+ (funcall test (- (if v 1 0) cv))))))))))
      ((and (eq kind :any) (stringp c))
       (let ((cmp (make-comparator :string))
             (test (comparison-test op)))
         (declare (type function cmp test))
         (compile-memoized-unary (compile-vexpr column-expr)
                                 (lambda (v) (funcall test (funcall cmp v c))))))
      ((and (eq kind :any) (integerp c))
       ;; Wide DECIMAL operand: unscaled values are unbounded integers.
       (let ((kernel (compile-vexpr column-expr)))
         (declare (type function kernel))
         (macrolet ((generic (test)
                      `(lambda (batch)
                         (let* ((n (batch-count batch))
                                (x (vec-data (funcall kernel batch)))
                                (out (make-array n)))
                           (declare (type simple-vector x) (type fixnum n))
                           (dotimes (i n (make-vec out))
                             (setf (svref out i)
                                   (let ((a (svref x i)) (b c))
                                     (declare (type integer b))
                                     (if (eq a +null+) +null+ ,test))))))))
           (comparison-dispatch op generic))))
      (t nil))))

(defun comparison-test (op)
  "Function of a comparator result (-1/0/1) implementing comparison OP."
  (ecase op
    (:= (lambda (c) (= c 0))) (:<> (lambda (c) (/= c 0)))
    (:< (lambda (c) (< c 0))) (:<= (lambda (c) (<= c 0)))
    (:> (lambda (c) (> c 0))) (:>= (lambda (c) (>= c 0)))))

;;; ------------------------------------------------------------------
;;; Dictionary-aware evaluation: a NULL-propagating function of one STRING
;;; operand is computed once per distinct dictionary entry.

(defun derived-dictionary (dict fn)
  "A DICT-COLUMN whose entries are FN of the entries of the DICT-COLUMN DICT
(possibly with duplicates), or NIL when FN fails on an entry or does not
return a string."
  (let ((entries (handler-case (map 'simple-vector fn (dict-column-dictionary dict))
                   (pq-error () nil))))
    (when (and entries (every #'stringp entries))
      (make-dict-column :length (length entries) :codes (make-array 0 :element-type '(unsigned-byte 32))
                        :dictionary entries))))

(defun compile-memoized-unary (kernel fn &optional (kind :any) derive-codes)
  "Kernel applying FN to the non-NULL values of KERNEL's :ANY vector (NULL
stays NULL). Values carrying dictionary codes are looked up in a per-entry
memo of FN's results, kept for the last dictionary seen. With DERIVE-CODES
(FN maps strings to strings), results of dictionary-coded values keep the
codes, into the dictionary of FN's results (see DERIVED-DICTIONARY), so
that expressions over them are again evaluated once per entry."
  (declare (type function kernel fn))
  (let ((memo-dict nil)
        (memo #())
        (derived nil)
        (unknown '#:unknown))
    (lambda (batch)
      (let* ((n (batch-count batch))
             (vec (funcall kernel batch))
             (data (vec-data vec))
             (codes (vec-codes vec))
             (out (make-array n))
             (coded nil))
        (declare (type simple-vector data out) (type fixnum n))
        (if codes
            (let ((dict (vec-dict vec)))
              (unless (eq dict memo-dict)
                (setf memo-dict dict
                      derived (and derive-codes (derived-dictionary dict fn))
                      memo (if derived
                               (copy-seq (dict-column-dictionary derived))
                               (make-array (length (dict-column-dictionary dict))
                                           :initial-element unknown))))
              (let ((memo memo))
                (declare (type simple-vector memo))
                (dotimes (i n)
                  (setf (svref out i)
                        (let ((v (svref data i)))
                          (if (eq v +null+)
                              +null+
                              (let* ((code (aref codes i))
                                     (r (svref memo code)))
                                (if (eq r unknown)
                                    (setf (svref memo code) (funcall fn v))
                                    r)))))))
              (setf coded (and derived t)))
            (dotimes (i n)
              (setf (svref out i)
                    (let ((v (svref data i)))
                      (if (eq v +null+) +null+ (funcall fn v))))))
        (cond (coded (make-vec out nil codes derived))
              ((eq kind :any) (make-vec out))
              (t (vec-from-values kind out n)))))))

(defun compile-vcall-of-string (e)
  "Kernel of a NULL-propagating scalar function call with one STRING
argument, computed once per dictionary entry of dictionary-coded input
(COMPILE-MEMOIZED-UNARY), or NIL for other calls."
  (let ((args (b-op-args e))
        (info (b-op-info e)))
    (when (and (= (length args) 1)
               (eq (type-kind (bexpr-type (first args))) :string)
               (scalar-function-p info)
               (not (scalar-function-null-aware info))
               (not (scalar-function-test-only info)))
      (let* ((arg (first args))
             (call (compile-bexpr (make-b-op (bexpr-type e) :call
                                             (list (make-b-column (bexpr-type arg) 0 "arg"))
                                             info)))
             (kind (type-vec-kind (bexpr-type e))))
        (declare (type function call))
        (compile-memoized-unary (compile-vexpr arg)
                                (lambda (v) (funcall call (vector v)))
                                kind
                                (eq (type-kind (bexpr-type e)) :string))))))

(defun compile-vlike (e)
  "LIKE with a constant pattern over a STRING operand, or NIL."
  (destructuring-bind (s p) (b-op-args e)
    (multiple-value-bind (pattern ok) (constant-operand-value p)
      (when (and ok (eq (type-vec-kind (bexpr-type s)) :any))
        (if (eq pattern +null+)
            (let ((kernel (compile-vexpr s)))
              (declare (type function kernel))
              (lambda (batch)
                (funcall kernel batch)
                (constant-vec :any +null+ (batch-count batch))))
            (compile-memoized-unary (compile-vexpr s)
                                    (lambda (v) (like-match-p v pattern))))))))

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
                                    ;; Wide DECIMALs use the generic path.
                                    (and (eq rk :decimal) (member op '(:+ :- :*))
                                         (notany #'wide-decimal-type-p
                                                 (list (bexpr-type e) (bexpr-type a) (bexpr-type b))))))
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
                  (limit (pow10 +narrow-decimal-precision+)))
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
                       (not (wide-decimal-type-p (bexpr-type a)))
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
            (not (wide-decimal-type-p from)) (not (wide-decimal-type-p to))
            (>= (decimal-scale to) (if (decimal-type-p from) (decimal-scale from) 0)))
       ;; Exact rescaling between narrow types; values needing more than the
       ;; target precision overflow.
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
           (whens (loop for (c) on pairs by #'cddr repeat n-when collect (compile-operand c)))
           (thens (loop for (nil r) on pairs by #'cddr repeat n-when collect (compile-operand r)))
           (else (when else-p (compile-operand (car (last pairs)))))
           (operand-kernel (when simple-p (compile-vexpr operand)))
           (tests (when simple-p
                    (loop for (c) on pairs by #'cddr
                          repeat n-when
                          collect (make-equality-test (bexpr-type operand) (bexpr-type c)))))
           (kind (type-vec-kind (bexpr-type e))))
      (flet ((eval-op (op batch idx m)
               (eval-subset (operand-kernel op) (operand-refs op) batch idx m)))
        (if (and (not simple-p)
                 (<= n-when +max-vector-operands+)
                 (notany #'operand-may-fail (append whens thens (and else (list else)))))
            (compile-eager-case whens thens else kind)
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
                  for tail = tests then (rest tail)
                  for k of-type fixnum from 1
                  while (plusp rcount)
                  do (when (zerop (mod k 64))
                       (check-interrupts))  ; CASE with thousands of branches
                     (let ((cond-vec (eval-op w batch remaining rcount))
                           (hits (make-index-vector rcount)) (h 0)
                           (rest (make-index-vector rcount)) (r 0))
                       (declare (type fixnum h r))
                       (dotimes (j rcount)
                         (let* ((row (aref remaining j))
                                (c (vec-ref cond-vec j))
                                (hit (if operand-vec
                                         (and (not (eq c +null+))
                                              (funcall (the function (first tail))
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
              ;; The ELSE rows (ascending): unmatched rows and NULL operands.
              (let ((pending (make-array n :element-type 'bit :initial-element 0))
                    (idx (make-index-vector n))
                    (m 0))
                (declare (type fixnum m))
                (dotimes (j rcount) (setf (sbit pending (aref remaining j)) 1))
                (dolist (row unmatched-null-operand) (setf (sbit pending row) 1))
                (dotimes (i n)
                  (when (= 1 (sbit pending i))
                    (setf (aref idx m) i)
                    (incf m)))
                (when (plusp m)
                  (let ((values (eval-op else batch idx m)))
                    (dotimes (j m)
                      (setf (svref out (aref idx j)) (vec-ref values j)))))))
            (vec-from-values kind out n))))))))

(defun compile-eager-case (whens thens else kind)
  "Searched CASE whose operands cannot fail: every operand is evaluated on
the whole batch and each row picks its branch."
  (let ((when-kernels (map 'simple-vector #'operand-kernel whens))
        (then-kernels (map 'simple-vector #'operand-kernel thens))
        (else-kernel (and else (operand-kernel else))))
    (lambda (batch)
      (let* ((n (batch-count batch))
             (conds (map 'simple-vector (lambda (k) (vec-data (funcall (the function k) batch)))
                         when-kernels))
             (results (map 'simple-vector (lambda (k) (funcall (the function k) batch)) then-kernels))
             (else-vec (and else-kernel (funcall (the function else-kernel) batch)))
             (m (length conds)))
        (declare (type simple-vector conds results) (type fixnum n m))
        (build-vec kind n
                   (lambda (i)
                     (declare (type fixnum i))
                     (dotimes (k m (if else-vec (vec-ref else-vec i) +null+))
                       (when (eq (svref (the simple-vector (svref conds k)) i) t)
                         (return (vec-ref (svref results k) i))))))))))
