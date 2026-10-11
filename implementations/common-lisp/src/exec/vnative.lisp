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
;;;;
;;;; A native Filter directly above a TableScan reads *lazy* batches (a
;;;; segment and a row range, no vectors): its predicates run on the column
;;;; stores in place (kernels take an element offset) and only the rows that
;;;; pass are copied out of the stores, instead of copying every scanned row
;;;; into batch vectors first.

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

(defun gather-validity (src-validity idx m &optional (offset 0))
  "Validity of the rows OFFSET+IDX[0..M) of SRC-VALIDITY (NIL: no NULLs)."
  (declare (type (or null simple-bit-vector) src-validity) (type u32-vector idx)
           (type fixnum m offset))
  (let ((validity nil))
    (when src-validity
      (dotimes (k m)
        (when (zerop (sbit src-validity (+ offset (aref idx k))))
          (unless validity (setf validity (make-validity m)))
          (setf (sbit validity k) 0))))
    validity))

(defun vec-gather-u32 (vec idx m)
  "VEC of the rows IDX[0..M) of VEC (IDX a U32-VECTOR of valid row numbers)."
  (declare (type u32-vector idx) (type fixnum m))
  (let ((data (vec-data vec))
        (validity (gather-validity (vec-validity vec) idx m)))
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
;;; Lazy scan batches

(defstruct (scan-source (:constructor make-scan-source (segment start end column-indexes kinds)))
  "The rows [START, END) of the column-layout SEGMENT, of which a TableScan
reads the table columns COLUMN-INDEXES (vector kinds KINDS)."
  segment
  (start 0 :type fixnum)
  (end 0 :type fixnum)
  (column-indexes #() :type simple-vector)
  (kinds #() :type simple-vector))

(defun make-lazy-scan-batch (segment column-indexes kinds start end)
  (make-lazy-batch (- end start)
                   (make-array (length kinds) :initial-element nil)
                   (make-scan-source segment start end
                                     (coerce column-indexes 'simple-vector)
                                     (coerce kinds 'simple-vector))))

(defun source-store (source k)
  "The column store of batch column K of the SCAN-SOURCE."
  (segment-column (scan-source-segment source) (svref (scan-source-column-indexes source) k)))

(defun batch-materialize (batch)
  "BATCH with its column vectors (built now for a lazy batch)."
  (let ((source (batch-source batch)))
    (when source
      (let ((start (scan-source-start source))
            (end (scan-source-end source))
            (columns (batch-columns batch)))
        (dotimes (k (length columns))
          (setf (svref columns k) (store-vec (source-store source k) start end
                                             (svref (scan-source-kinds source) k))))
        (setf (batch-source batch) nil)))
    batch))

(defun store-gather (store kind start idx m)
  "VEC of KIND holding the rows START+IDX[0..M) of the column STORE, equal to
gathering them from (STORE-VEC STORE ...)."
  (declare (type u32-vector idx) (type fixnum start m))
  (let ((validity (column-store-validity store)))
    (cond
      ((and (eq kind :i64) (int-column-p store))
       (make-vec (native-gather (int-column-values store) idx m
                                (make-array m :element-type '(signed-byte 64)) start)
                 (gather-validity validity idx m start)))
      ((and (eq kind :f64) (float-column-p store))
       (make-vec (native-gather (float-column-values store) idx m
                                (make-array m :element-type 'double-float) start)
                 (gather-validity validity idx m start)))
      ((and (eq kind :any) (dict-column-p store))
       (let ((codes (dict-column-codes store))
             (dict (dict-column-dictionary store))
             (out (make-array m))
             (out-codes (make-array m :element-type '(unsigned-byte 32))))
         (declare (type u32-vector codes) (type simple-vector dict))
         (dotimes (k m)
           (let* ((row (+ start (aref idx k)))
                  (code (aref codes row)))
             (setf (aref out-codes k) code
                   (svref out k) (if (and validity (zerop (sbit validity row)))
                                     +null+
                                     (svref dict code)))))
         (make-vec out nil out-codes store)))
      ((and (eq kind :any) (string-column-p store))
       (let ((values (string-column-values store))
             (out (make-array m)))
         (dotimes (k m)
           (let ((row (+ start (aref idx k))))
             (setf (svref out k) (if (and validity (zerop (sbit validity row)))
                                     +null+
                                     (svref values row)))))
         (make-vec out)))
      (t
       (let ((read (column-reader store)))
         (declare (type function read))
         (build-vec kind m (lambda (k) (funcall read (+ start (aref idx k))))))))))

(defun select-rows (batch idx m)
  "The rows IDX[0..M) (ascending) of BATCH as a materialized batch: BATCH
itself when all its rows are selected, NIL when none is."
  (let ((n (batch-count batch))
        (source (batch-source batch)))
    (cond ((zerop m) nil)
          ((= m n) (batch-materialize batch))
          (source
           (let ((kinds (scan-source-kinds source))
                 (start (scan-source-start source)))
             (make-batch m (let ((columns (make-array (length kinds))))
                             (dotimes (k (length kinds) columns)
                               (setf (svref columns k)
                                     (store-gather (source-store source k) (svref kinds k)
                                                   start idx m)))))))
          (t (batch-gather-u32 batch idx m)))))

;;; ------------------------------------------------------------------
;;; Operands: (batch) -> (values data offset validity), the operand's values
;;; being DATA[OFFSET + i] for the batch's rows i.

(defun compile-i64-operand (e)
  "Accessor of the INT64-like expression E. A column of a lazy batch is read
in place from an INT64 column store."
  (let ((kernel (compile-vexpr e)))
    (declare (type function kernel))
    (flet ((evaluate (batch)
             (multiple-value-bind (data validity)
                 (vec-i64-data (funcall kernel (batch-materialize batch)) (batch-count batch))
               (values data 0 validity))))
      (if (b-column-p e)
          (let ((k (b-column-index e)))
            (lambda (batch)
              (let* ((source (batch-source batch))
                     (store (and source (source-store source k))))
                (if (and store (int-column-p store))
                    (let ((start (scan-source-start source))
                          (validity (column-store-validity store)))
                      (values (int-column-values store) start
                              (and validity (subseq validity start (scan-source-end source)))))
                    (evaluate batch)))))
          #'evaluate))))

(defun compile-validity-operand (e)
  "Function (batch) -> the validity bitmap of E's values (NIL: no NULLs)."
  (let ((kernel (compile-vexpr e)))
    (declare (type function kernel))
    (flet ((evaluate (batch)
             (vec-validity-bits (funcall kernel (batch-materialize batch)) (batch-count batch))))
      (if (b-column-p e)
          (let ((k (b-column-index e)))
            (lambda (batch)
              (let ((source (batch-source batch)))
                (if source
                    (let ((validity (column-store-validity (source-store source k))))
                      (and validity
                           (subseq validity (scan-source-start source) (scan-source-end source))))
                    (evaluate batch)))))
          #'evaluate))))

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

;;; ------------------------------------------------------------------
;;; Native predicates

(defstruct (native-predicate (:constructor make-native-predicate (fn &optional simple)))
  ;; FN: (batch) -> (values true-bits valid-bits); VALID-BITS NIL = never NULL.
  (fn nil :type function)
  ;; For `x op constant(s)`: (operand op a b), evaluated by pqk_filter_i64
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

(defun native-filter-predicate (operand op a b)
  "Native predicate op(OPERAND, A, B) for constants A, B."
  (let ((access (compile-i64-operand operand)))
    (declare (type function access))
    (make-native-predicate
     (lambda (batch)
       (let ((n (batch-count batch)))
         (multiple-value-bind (data offset validity) (funcall access batch)
           (let ((out (make-bits n)))
             (native-filter-i64-bitmap data validity n op a b out offset)
             (values out validity)))))
     (list access op a b))))

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
         (let ((access-a (compile-i64-operand a))
               (access-b (compile-i64-operand b))
               (pqk-op (pqk-comparison-op op)))
           (declare (type function access-a access-b))
           (make-native-predicate
            (lambda (batch)
              (let ((n (batch-count batch)))
                (multiple-value-bind (x ox vx) (funcall access-a batch)
                  (multiple-value-bind (y oy vy) (funcall access-b batch)
                    (let ((out (make-bits n))
                          (valid (cond ((and vx vy) (bits-and vx vy n)) (vx) (vy))))
                      (native-compare-i64 x y n pqk-op out ox oy)
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
        (let ((access (compile-i64-operand x))
              (values (remove-duplicates values)))
          (declare (type function access))
          (make-native-predicate
           (lambda (batch)
             (let ((n (batch-count batch))
                   (bits nil))
               (multiple-value-bind (data offset validity) (funcall access batch)
                 (dolist (c values)
                   (let ((out (make-bits n)))
                     (native-filter-i64-bitmap data validity n +pqk-eq+ c 0 out offset)
                     (setf bits (if bits (native-bitmap-or bits out bits n) out))))
                 (values bits validity))))))))))

(defun native-null-test (x want-null)
  (when (and (not (bexpr-constant-p x)) (member (type-vec-kind (bexpr-type x)) '(:i64 :f64)))
    (let ((access (compile-validity-operand x)))
      (declare (type function access))
      (make-native-predicate
       (lambda (batch)
         (let* ((n (batch-count batch))
                (validity (funcall access batch)))
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
  "Function (batch) -> the rows of the (possibly lazy) batch satisfying
PREDICATE as a materialized batch (the batch itself when all rows do, NIL
when none does), evaluating its leading conjuncts with native kernels; NIL
when no conjunct has a native evaluation."
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
             (rest-may-fail (and rest-expr (may-fail-p rest-expr)))
             (guard (make-row-order-guard (list predicate))))
        (declare (type function guard))
        (labels ((simple-filter (batch)
                   ;; One `x op constant(s)` conjunct: indices straight from
                   ;; pqk_filter_i64.
                   (destructuring-bind (access op a b) simple
                     (let ((n (batch-count batch)))
                       (multiple-value-bind (data offset validity) (funcall (the function access) batch)
                         (let ((idx (make-array n :element-type '(unsigned-byte 32))))
                           (select-rows batch idx (native-filter-i64 data validity n op a b idx offset)))))))
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
                         (multiple-value-call #'select-rows batch (bits-selection true n))
                         ;; The other conjuncts, on (a batch of) the rows the
                         ;; row executor evaluates them for; a data error is
                         ;; replaced by the row executor's first one on them.
                         (multiple-value-bind (sidx sm) (bits-selection (if rest-may-fail not-false true) n)
                           (declare (type u32-vector sidx) (type fixnum sm))
                           (let ((candidates (select-rows batch sidx sm)))
                             (when candidates
                               (let ((values (vec-data (funcall guard candidates
                                                                (lambda () (funcall rest-kernel candidates)))))
                                     (out (make-array sm :element-type '(unsigned-byte 32)))
                                     (m 0))
                                 (declare (type simple-vector values) (type fixnum m))
                                 (dotimes (j sm)
                                   (when (and (eq (svref values j) t)
                                              (or (not rest-may-fail) (= 1 (sbit true (aref sidx j)))))
                                     (setf (aref out m) j)
                                     (incf m)))
                                 (select-rows candidates out m)))))))))
          (if simple #'simple-filter #'general-filter))))))

(defun make-native-scan-filter (scan predicate &key ranges)
  "Batch opener of Filter(PREDICATE) directly above the TableScan SCAN
reading lazy batches (see MAKE-BATCH-SCAN), or NIL unless the statement
uses native kernels and some conjunct of PREDICATE has a native evaluation."
  (let ((filter (and (native-kernels-enabled-p) (compile-native-filter predicate))))
    (when filter
      (let ((open-scan (make-batch-scan scan :ranges ranges :lazy t)))
        (declare (type function filter open-scan))
        (lambda ()
          (let ((child (funcall open-scan)))
            (declare (type function child))
            (lambda ()
              (loop
                (let ((batch (funcall child)))
                  (unless batch (return nil))
                  (let ((out (funcall filter batch)))
                    (when out (return out))))))))))))

;;; ------------------------------------------------------------------
;;; Aggregation of lazy batches: without GROUP BY, aggregates whose argument
;;; is a scanned column (or COUNT(*)) are computed on the column stores in
;;; place (AGG-UPDATE-STORE); the batch is materialized only for an
;;; aggregate no kernel applies to.

(defun lazy-aggregation-columns (keys aggs)
  "(values ok columns): whether an aggregation with GROUP BY KEYS and the
aggregate calls AGGS can consume lazy batches, and per aggregate the batch
column of its argument (NIL for COUNT(*))."
  (if (and (null keys)
           (every (lambda (a)
                    (or (eq (b-agg-fn a) :count-star)
                        (and (not (b-agg-distinct a))
                             (member (b-agg-fn a) '(:count :sum :avg :min :max))
                             (b-column-p (first (b-agg-args a))))))
                  aggs))
      (values t (mapcar (lambda (a) (and (b-agg-args a) (b-column-index (first (b-agg-args a)))))
                        aggs))
      (values nil nil)))

(defun group-state-consume-lazy (gs batch columns)
  "Aggregate the lazy BATCH into the group state GS (no GROUP BY); COLUMNS
as returned by LAZY-AGGREGATION-COLUMNS."
  (let* ((source (batch-source batch))
         (start (scan-source-start source))
         (end (scan-source-end source))
         (n (batch-count batch))
         (gids (group-state-gids gs)))
    (when (> n (length gids))
      (setf gids (make-index-vector n)
            (group-state-gids gs) gids)
      (fill gids 0))
    (loop for s across (group-state-aggs gs)
          for k in columns
          do (unless (and k (batch-source batch)
                          (agg-update-store s (source-store source k) start end))
               (let ((vec (and k (svref (batch-columns (batch-materialize batch)) k))))
                 (unless (and vec (agg-update-native s nil nil vec n))
                   (agg-update s gids vec n)))))))
