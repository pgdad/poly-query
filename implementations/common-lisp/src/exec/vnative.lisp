;;;; vnative.lisp — native-kernel filters for the vectorized executor.
;;;;
;;;; With `native: true` (and the library loaded) a Filter evaluates the
;;;; conjuncts of its predicate that are simple integer predicates with the
;;;; kernels of libpqkernels (native/kernels.lisp) instead of the Lisp
;;;; kernels of vexpressions.lisp:
;;;;   x op c, c op x, x BETWEEN c1 AND c2   pqk_filter_i64[_bitmap]
;;;;   x IN (c1, ..., ck)                     one pqk_filter_i64_bitmap per value, OR-ed
;;;;   x op y                                 pqk_compare_i64 AND-ed with the validities
;;;;   x IS [NOT] NULL                        the validity bitmap
;;;;   AND / OR / NOT of the above            pqk_bitmap_and / _or / _andnot
;;;; where x, y are INT64-like (INT64, DECIMAL, DATE, TIMESTAMP) operands and
;;;; the constants c are converted once to x's representation exactly as the
;;;; Lisp comparison kernels do. A native predicate evaluates to two bitmaps:
;;;; the rows where it is TRUE and the rows where it is not NULL, so SQL's
;;;; three-valued logic is preserved through NOT and OR. (Bitmaps returned
;;;; by a predicate are never modified afterwards, so they may be shared.)
;;;;
;;;; Only conjuncts that cannot fail are evaluated natively, and only those
;;;; before the first conjunct that may fail: the remaining conjuncts are
;;;; then evaluated (by the Lisp kernels) on exactly the rows where the row
;;;; executor would evaluate them, so errors are the same as without native
;;;; kernels. The surviving rows are gathered with pqk_gather_i64.

(in-package #:polyquery)

;;; ------------------------------------------------------------------
;;; Bitmaps (SIMPLE-BIT-VECTORs of a batch's N rows)

(defun make-bits (n &optional (initial 0))
  (make-array n :element-type 'bit :initial-element initial))

(defun bits-and (a b n) (native-bitmap-and a b (make-bits n) n))
(defun bits-or (a b n) (native-bitmap-or a b (make-bits n) n))
(defun bits-andnot (a b n) (native-bitmap-andnot a b (make-bits n) n))

(defun bits-or-ones (bits n)
  "BITS, or an all-ones bitmap for NIL (a NIL validity: every row valid)."
  (or bits (make-bits n 1)))

(defun bits-selection (bits n)
  "(values idx m): the U32-VECTOR of the set bits among the first N of BITS
(ascending) and their number."
  (declare (type simple-bit-vector bits) (type fixnum n))
  (let ((out (make-array n :element-type '(unsigned-byte 32)))
        (m 0))
    (declare (type fixnum m))
    (dotimes (w (ceiling n 64))
      (let ((word (sb-kernel:%vector-raw-bits bits w))
            (base (* w 64)))
        (declare (type (unsigned-byte 64) word) (type fixnum base))
        (when (> (+ base 64) n)                 ; ignore bits past the last row
          (setf word (ldb (byte (- n base) 0) word)))
        (loop until (zerop word)
              do (setf (aref out m) (+ base (1- (integer-length (logxor word (1- word))))))
                 (incf m)
                 (setf word (logand word (1- word))))))
    (values out m)))

;;; ------------------------------------------------------------------
;;; Gathering with a U32 selection

(defun vec-gather-u32 (vec idx m)
  "VEC of the rows IDX[0..M) of VEC (IDX a U32-VECTOR of valid row numbers)."
  (declare (type u32-vector idx) (type fixnum m))
  (let* ((data (vec-data vec))
         (src-validity (vec-validity vec))
         (validity nil))
    (declare (type (or null simple-bit-vector) src-validity))
    (when src-validity
      (dotimes (k m)
        (when (zerop (sbit src-validity (aref idx k)))
          (unless validity (setf validity (make-validity m)))
          (setf (sbit validity k) 0))))
    (etypecase data
      (i64-vector
       (make-vec (native-gather data idx m (make-array m :element-type '(signed-byte 64)))
                 validity))
      (f64-vector
       (make-vec (native-gather data idx m (make-array m :element-type 'double-float))
                 validity))
      (simple-vector
       (let ((out (make-array m))
             (codes (vec-codes vec)))
         (dotimes (k m)
           (setf (svref out k) (svref data (aref idx k))))
         (if codes
             (let ((out-codes (make-array m :element-type '(unsigned-byte 32))))
               (dotimes (k m)
                 (setf (aref out-codes k) (aref codes (aref idx k))))
               (make-vec out nil out-codes (vec-dict vec)))
             (make-vec out)))))))

(defun batch-gather-u32 (batch idx m)
  (make-batch m (map 'simple-vector (lambda (v) (and v (vec-gather-u32 v idx m)))
                     (batch-columns batch))))

;;; ------------------------------------------------------------------
;;; Native predicates

(defstruct (native-predicate (:constructor make-native-predicate (fn &optional simple)))
  ;; FN: (batch) -> (values true-bits valid-bits); VALID-BITS NIL = never NULL.
  (fn nil :type function)
  ;; For `x op constant(s)`: (kernel op a b), evaluated by pqk_filter_i64
  ;; when it is a filter's only conjunct.
  (simple nil))

(defun pqk-comparison-op (op)
  (ecase op
    (:= +pqk-eq+) (:<> +pqk-ne+) (:< +pqk-lt+) (:<= +pqk-le+) (:> +pqk-gt+) (:>= +pqk-ge+)))

(defun i64-operand-p (e)
  (and (not (bexpr-constant-p e)) (eq (type-vec-kind (bexpr-type e)) :i64)))

(defun native-constant (operand-type constant-expr)
  "The constant CONSTANT-EXPR in the representation of values of
OPERAND-TYPE for comparing with them (an INT64), or NIL when the comparison
does not compare the operand's values as they are, or the constant is NULL
or cannot be evaluated."
  (multiple-value-bind (nl nr) (comparison-normalizers operand-type (bexpr-type constant-expr))
    (when (eq nl #'identity)
      (multiple-value-bind (c ok) (normalized-constant constant-expr nr)
        (and ok (typep c '(signed-byte 64)) c)))))

(defun vec-i64-data (vec n)
  "(values data validity) of VEC as a (SIGNED-BYTE 64) vector."
  (if (typep (vec-data vec) 'i64-vector)
      (values (vec-data vec) (vec-validity vec))
      (let ((v (build-vec :i64 n (lambda (i) (vec-ref vec i)))))
        (values (vec-data v) (vec-validity v)))))

(defun vec-validity-bits (vec n)
  "Validity bitmap of VEC (NIL: no NULLs)."
  (if (simple-vector-p (vec-data vec))
      (and (vec-has-nulls-p vec n)
           (let ((bits (make-bits n 1)))
             (dotimes (i n bits)
               (when (eq (vec-ref vec i) +null+) (setf (sbit bits i) 0)))))
      (vec-validity vec)))

(defun native-filter-predicate (operand op a b)
  "Native predicate op(OPERAND, A, B) for constants A, B."
  (let ((kernel (compile-vexpr operand)))
    (declare (type function kernel))
    (make-native-predicate
     (lambda (batch)
       (let ((n (batch-count batch)))
         (multiple-value-bind (data validity) (vec-i64-data (funcall kernel batch) n)
           (let ((out (make-bits n)))
             (native-filter-i64-bitmap data validity n op a b out)
             (values out validity)))))
     (list kernel op a b))))

(defun native-comparison (op a b)
  (cond
    ((and (i64-operand-p a) (bexpr-constant-p b))
     (let ((c (native-constant (bexpr-type a) b)))
       (and c (native-filter-predicate a (pqk-comparison-op op) c 0))))
    ((and (bexpr-constant-p a) (i64-operand-p b))
     (native-comparison (flip-comparison-op op) b a))
    ((and (i64-operand-p a) (i64-operand-p b))
     (multiple-value-bind (nl nr) (comparison-normalizers (bexpr-type a) (bexpr-type b))
       (when (and (eq nl #'identity) (eq nr #'identity))
         (let ((ka (compile-vexpr a))
               (kb (compile-vexpr b))
               (pqk-op (pqk-comparison-op op)))
           (declare (type function ka kb))
           (make-native-predicate
            (lambda (batch)
              (let ((n (batch-count batch)))
                (multiple-value-bind (x vx) (vec-i64-data (funcall ka batch) n)
                  (multiple-value-bind (y vy) (vec-i64-data (funcall kb batch) n)
                    (let ((out (make-bits n))
                          (valid (cond ((and vx vy) (bits-and vx vy n)) (vx) (vy))))
                      (native-compare-i64 x y n pqk-op out)
                      (values (if valid (native-bitmap-and out valid out n) out)
                              valid)))))))))))
    (t nil)))

(defun native-between (x low high)
  (when (and (i64-operand-p x) (bexpr-constant-p low) (bexpr-constant-p high))
    (let ((lo (native-constant (bexpr-type x) low))
          (hi (native-constant (bexpr-type x) high)))
      (and lo hi (native-filter-predicate x +pqk-between+ lo hi)))))

(defparameter *native-in-list-limit* 16
  "Longest IN list evaluated with one filter kernel call per value.")

(defun native-in-list (x items)
  (when (and (i64-operand-p x) (<= (length items) *native-in-list-limit*)
             (every #'bexpr-constant-p items))
    (let ((values (mapcar (lambda (item) (native-constant (bexpr-type x) item)) items)))
      (when (every #'identity values)
        (let ((kernel (compile-vexpr x))
              (values (remove-duplicates values)))
          (declare (type function kernel))
          (make-native-predicate
           (lambda (batch)
             (let ((n (batch-count batch))
                   (bits nil))
               (multiple-value-bind (data validity) (vec-i64-data (funcall kernel batch) n)
                 (dolist (c values)
                   (let ((out (make-bits n)))
                     (native-filter-i64-bitmap data validity n +pqk-eq+ c 0 out)
                     (setf bits (if bits (native-bitmap-or bits out bits n) out))))
                 (values bits validity))))))))))

(defun native-null-test (x want-null)
  (when (and (not (bexpr-constant-p x)) (member (type-vec-kind (bexpr-type x)) '(:i64 :f64)))
    (let ((kernel (compile-vexpr x)))
      (declare (type function kernel))
      (make-native-predicate
       (lambda (batch)
         (let* ((n (batch-count batch))
                (validity (vec-validity-bits (funcall kernel batch) n)))
           (values (cond ((not want-null) (if validity (bits-and validity validity n) (make-bits n 1)))
                         (validity (bits-andnot (make-bits n 1) validity n))
                         (t (make-bits n 0)))
                   nil)))))))

(defun native-not (p)
  (let ((fn (native-predicate-fn p)))
    (make-native-predicate
     (lambda (batch)
       (multiple-value-bind (true valid) (funcall fn batch)
         (let ((n (batch-count batch)))
           (values (bits-andnot (bits-or-ones valid n) true n) valid)))))))

(defun native-logic (which p q)
  "Three-valued AND / OR of two native predicates."
  (let ((f (native-predicate-fn p))
        (g (native-predicate-fn q)))
    (make-native-predicate
     (lambda (batch)
       (let ((n (batch-count batch)))
         (multiple-value-bind (ta va) (funcall f batch)
           (multiple-value-bind (tb vb) (funcall g batch)
             (if (eq which :and)
                 ;; TRUE: both TRUE; not NULL: TRUE, or either FALSE.
                 (let ((true (bits-and ta tb n)))
                   (values true
                           (and (or va vb)
                                (bits-or (bits-or true (bits-andnot (bits-or-ones va n) ta n) n)
                                         (bits-andnot (bits-or-ones vb n) tb n)
                                         n))))
                 ;; TRUE: either TRUE; not NULL: TRUE, or both not NULL.
                 (let ((true (bits-or ta tb n)))
                   (values true
                           (and (or va vb)
                                (bits-or true (bits-and (bits-or-ones va n) (bits-or-ones vb n) n)
                                         n))))))))))))

(defun %compile-native-predicate (e)
  (when (b-op-p e)
    (let ((args (b-op-args e)))
      (case (b-op-op e)
        ((:= :<> :< :<= :> :>=) (native-comparison (b-op-op e) (first args) (second args)))
        (:between (apply #'native-between args))
        (:in-list (native-in-list (first args) (rest args)))
        (:is-null (native-null-test (first args) t))
        (:is-not-null (native-null-test (first args) nil))
        (:not (let ((p (%compile-native-predicate (first args))))
                (and p (native-not p))))
        ((:and :or)
         (let ((p (%compile-native-predicate (first args))))
           (when p
             (let ((q (%compile-native-predicate (second args))))
               (and q (native-logic (b-op-op e) p q))))))
        (t nil)))))

(defun compile-native-predicate (e)
  "NATIVE-PREDICATE evaluating the boolean expression E with the native
kernels, or NIL when E (or a part of it) has no native evaluation or may
fail."
  (and (not (may-fail-p e))
       (%compile-native-predicate e)))

;;; ------------------------------------------------------------------
;;; Filters

(defun compile-native-filter (predicate)
  "Function (batch) -> the rows of the batch satisfying PREDICATE (the batch
itself when all do, NIL when none does), evaluating its leading conjuncts
with native kernels; NIL when no conjunct has a native evaluation."
  (let* ((conjuncts (split-conjuncts predicate))
         (first-may-fail (or (position-if #'may-fail-p conjuncts) (length conjuncts)))
         (natives '())
         (rest '()))
    (loop for c in conjuncts
          for k from 0
          do (let ((p (and (< k first-may-fail) (compile-native-predicate c))))
               (if p (push p natives) (push c rest))))
    (setf natives (nreverse natives) rest (nreverse rest))
    (when natives
      (let* ((fns (mapcar #'native-predicate-fn natives))
             (simple (and (null rest) (null (rest natives)) (native-predicate-simple (first natives))))
             (rest-expr (conjoin rest))
             (rest-kernel (and rest-expr (compile-vexpr rest-expr)))
             (rest-refs (and rest-expr (bexpr-column-indexes rest-expr)))
             (rest-may-fail (and rest-expr (may-fail-p rest-expr)))
             (guard (make-row-order-guard (list predicate))))
        (declare (type function guard))
        (labels ((select (batch idx m)
                   (let ((n (batch-count batch)))
                     (cond ((= m n) batch)
                           ((zerop m) nil)
                           (t (batch-gather-u32 batch idx m)))))
                 (simple-filter (batch)
                   ;; One `x op constant(s)` conjunct: indices straight from
                   ;; pqk_filter_i64.
                   (destructuring-bind (kernel op a b) simple
                     (let ((n (batch-count batch)))
                       (multiple-value-bind (data validity) (vec-i64-data (funcall (the function kernel) batch) n)
                         (let ((idx (make-array n :element-type '(unsigned-byte 32))))
                           (select batch idx (native-filter-i64 data validity n op a b idx)))))))
                 (general-filter (batch)
                   (let ((n (batch-count batch))
                         (true nil)
                         (not-false nil))
                     ;; TRUE rows of the native conjuncts, and (when the rest
                     ;; may fail) the rows where none of them is FALSE.
                     (dolist (fn fns)
                       (multiple-value-bind (tk vk) (funcall (the function fn) batch)
                         (setf true (if true (bits-and true tk n) tk))
                         (when rest-may-fail
                           (let ((nf (if vk (bits-or tk (bits-andnot (make-bits n 1) vk n) n) tk)))
                             (setf not-false (if not-false (bits-and not-false nf n) nf))))))
                     (if (null rest-kernel)
                         (multiple-value-call #'select batch (bits-selection true n))
                         ;; The other conjuncts, on the rows the row executor
                         ;; evaluates them for.
                         (multiple-value-bind (sidx sm) (bits-selection (if rest-may-fail not-false true) n)
                           (declare (type u32-vector sidx) (type fixnum sm))
                           (when (plusp sm)
                             (let ((idx (make-index-vector sm)))
                               (dotimes (j sm) (setf (aref idx j) (aref sidx j)))
                               (let ((values (vec-data (funcall guard batch
                                                                (lambda ()
                                                                  (eval-subset rest-kernel rest-refs
                                                                               batch idx sm)))))
                                     (out (make-array sm :element-type '(unsigned-byte 32)))
                                     (m 0))
                                 (declare (type simple-vector values) (type fixnum m))
                                 (dotimes (j sm)
                                   (let ((row (aref sidx j)))
                                     (when (and (= 1 (sbit true row)) (eq (svref values j) t))
                                       (setf (aref out m) row)
                                       (incf m))))
                                 (select batch out m)))))))))
          (if simple #'simple-filter #'general-filter))))))
