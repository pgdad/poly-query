;;;; voperators.lisp — vectorized (batch-at-a-time) physical operators.
;;;;
;;;; COMPILE-BATCH-OPERATOR turns a physical plan node into a *batch opener*:
;;;; a function of no arguments returning a fresh iterator that yields
;;;; BATCHes (vectors.lisp) or NIL at the end. Scans, filters, projections,
;;;; limits, hash aggregation, DISTINCT and hash joins are vectorized; every
;;;; other operator (sort, top-N, merge and nested-loop joins, index scans,
;;;; ...) runs its row implementation over adapted inputs, so the two
;;;; executors always agree. The MAKE-BATCH-* constructors take their input
;;;; openers as arguments so the parallel executor (parallel.lisp) can build
;;;; one copy of a pipeline per worker.

(in-package #:polyquery)

(defgeneric compile-batch-operator (node)
  (:documentation "Return the batch opener implementing physical plan NODE."))

(defun output-kinds (node)
  (column-kinds (pnode-columns node)))

;;; ------------------------------------------------------------------
;;; Row operators over batch inputs

(defmethod compile-operator ((node pp-batch-source))
  (batches-to-rows-opener (pp-batch-source-opener node)))

(defmethod compile-batch-operator ((node pnode))
  ;; Operators without a batch implementation run row-at-a-time over their
  ;; (vectorized) inputs.
  (let ((copy (copy-structure node)))
    (setf (pnode-children copy)
          (mapcar (lambda (child)
                    (make-pp-batch-source :opener (compile-batch-operator child)
                                          :columns (pnode-columns child)
                                          :invariant (plan-invariant-p child)))
                  (pnode-children node)))
    (rows-to-batches-opener (compile-operator copy) (output-kinds node))))

;;; ------------------------------------------------------------------
;;; Scans

(defun segment-batch (segment column-indexes kinds start end)
  (make-batch (- end start)
              (map 'simple-vector (lambda (k kind) (segment-vec segment k start end kind))
                   column-indexes kinds)))

(defun scan-segments (node)
  "The segments a TableScan reads (those not excluded by segment skipping)."
  (let ((skip-p (compile-skip-test (pp-table-scan-table node) (pp-table-scan-skips node))))
    (remove-if (lambda (seg)
                 (or (zerop (segment-count seg)) (and skip-p (funcall skip-p seg))))
               (coerce (table-segments (pp-table-scan-table node)) 'list))))

(defun make-batch-scan (node &key ranges)
  "Batch opener of a TableScan. RANGES, when given, is a function returning
the next (segment start end) range to read or NIL (parallel morsels);
otherwise all unskipped segments are read in order."
  (let ((column-indexes (pp-table-scan-column-indexes node))
        (kinds (output-kinds node)))
    (lambda ()
      (let ((next-range
              (or ranges
                  (let ((segments (scan-segments node))
                        (pos 0))
                    (declare (type fixnum pos))
                    (lambda ()
                      (loop
                        (let ((seg (first segments)))
                          (cond ((null seg) (return nil))
                                ((< pos (segment-count seg))
                                 (let ((end (min (segment-count seg) (+ pos +batch-size+))))
                                   (return (prog1 (list seg pos end) (setf pos end)))))
                                (t (pop segments) (setf pos 0)))))))))
            (seg nil) (pos 0) (end 0))
        (declare (type function next-range) (type fixnum pos end))
        (lambda ()
          (check-interrupts)
          (loop
            (when (< pos end)
              (let ((stop (min end (+ pos +batch-size+))))
                (return (prog1 (segment-batch seg column-indexes kinds pos stop)
                          (setf pos stop)))))
            (let ((range (funcall next-range)))
              (unless range (return nil))
              (destructuring-bind (s start stop) range
                (setf seg s pos start end stop)))))))))

(defmethod compile-batch-operator ((node pp-table-scan))
  (make-batch-scan node))

(defmethod compile-batch-operator ((node pp-values))
  (lambda ()
    (let ((done nil))
      (lambda ()
        (unless done
          (setf done t)
          (make-batch 1 (vector)))))))

;;; ------------------------------------------------------------------
;;; Filter, projection, limit

(defun make-batch-filter (open-child predicate)
  (let ((kernel (compile-vexpr predicate)))
    (declare (type function open-child kernel))
    (lambda ()
      (let ((child (funcall open-child)))
        (declare (type function child))
        (lambda ()
          (loop
            (let ((batch (funcall child)))
              (unless batch (return nil))
              (let ((out (filter-batch batch (funcall kernel batch))))
                (when out (return out))))))))))

(defmethod compile-batch-operator ((node pp-filter))
  (make-batch-filter (compile-batch-operator (pnode-child node)) (pp-filter-predicate node)))

(defun make-batch-project (open-child exprs)
  (let ((kernels (map 'simple-vector #'compile-vexpr exprs)))
    (declare (type function open-child))
    (lambda ()
      (let ((child (funcall open-child)))
        (declare (type function child))
        (lambda ()
          (let ((batch (funcall child)))
            (when batch
              (make-batch (batch-count batch)
                          (map 'simple-vector (lambda (k) (funcall (the function k) batch))
                               kernels)))))))))

(defmethod compile-batch-operator ((node pp-project))
  (make-batch-project (compile-batch-operator (pnode-child node)) (pp-project-exprs node)))

(defmethod compile-batch-operator ((node pp-limit))
  (let ((open-child (compile-batch-operator (pnode-child node)))
        (limit (evaluate-limit-expr (pp-limit-limit node) "LIMIT"))
        (offset (or (evaluate-limit-expr (pp-limit-offset node) "OFFSET") 0)))
    (declare (type function open-child))
    (lambda ()
      (if (eql limit 0)
          (lambda () nil)
          (let ((child (funcall open-child))
                (skip offset)
                (remaining limit))
            (declare (type function child))
            (lambda ()
              (loop
                (when (and remaining (<= remaining 0)) (return nil))
                (let ((batch (funcall child)))
                  (unless batch (return nil))
                  (let* ((n (batch-count batch))
                         (start (min skip n))
                         (end (if remaining (min n (+ start remaining)) n)))
                    (decf skip start)
                    (when (< start end)
                      (when remaining (decf remaining (- end start)))
                      (return (if (and (= start 0) (= end n))
                                  batch
                                  (batch-slice batch start end)))))))))))))

;;; ------------------------------------------------------------------
;;; Aggregation

(defun make-aggregate-consumer (node)
  "(values new-state consume) for vectorized aggregation of NODE: NEW-STATE
creates an empty GROUP-STATE, (CONSUME state batch) aggregates one input
batch into it. Kernels are compiled once per call."
  (let* ((keys (pp-hash-aggregate-group-by node))
         (aggs (pp-hash-aggregate-aggregates node))
         (key-kernels (mapcar #'compile-vexpr keys))
         (arg-kernels (mapcar (lambda (a) (and (b-agg-args a) (compile-vexpr (first (b-agg-args a)))))
                              aggs))
         (nkeys (length keys))
         (charged 0))
    (declare (type fixnum charged))
    (values
     (lambda () (make-group-state nkeys aggs))
     (lambda (gs batch)
       (let ((n (batch-count batch)))
         (group-state-consume gs
                              (mapcar (lambda (k) (funcall (the function k) batch)) key-kernels)
                              (mapcar (lambda (k) (and k (funcall (the function k) batch))) arg-kernels)
                              n)
         (let ((groups (group-state-count gs)))
           (when (>= (- groups charged) 1024)
             (charge-memory (* (- groups charged) (row-footprint (* 4 (+ nkeys (length aggs))))))
             (setf charged groups))))))))

(defun group-state-batches (gs node)
  "Iterator over the output batches of the finished group state GS."
  (let* ((nkeys (length (pp-hash-aggregate-group-by node)))
         (kinds (output-kinds node))
         (key-kinds (subseq kinds 0 nkeys))
         (agg-kinds (subseq kinds nkeys))
         (count (group-state-count gs))
         (pos 0))
    (declare (type fixnum pos))
    (lambda ()
      (when (< pos count)
        (let ((end (min count (+ pos +batch-size+))))
          (prog1 (group-state-batch gs pos end key-kinds agg-kinds)
            (setf pos end)))))))

(defun make-batch-aggregate (open-child node)
  (declare (type function open-child))
  (multiple-value-bind (new-state consume) (make-aggregate-consumer node)
    (declare (type function new-state consume))
    (lambda ()
      (let ((output nil))
        (lambda ()
          (unless output
            (let ((gs (funcall new-state))
                  (child (funcall open-child)))
              (declare (type function child))
              (loop for batch = (funcall child)
                    while batch
                    do (funcall consume gs batch))
              (setf output (group-state-batches gs node))))
          (funcall (the function output)))))))

(defmethod compile-batch-operator ((node pp-hash-aggregate))
  (make-batch-aggregate (compile-batch-operator (pnode-child node)) node))

;;; DISTINCT streams: a row is emitted when its key tuple is seen first.
(defmethod compile-batch-operator ((node pp-hash-distinct))
  (let ((open-child (compile-batch-operator (pnode-child node)))
        (width (length (pnode-columns node))))
    (declare (type function open-child))
    (lambda ()
      (let ((child (funcall open-child))
            (table (make-key-table width)))
        (declare (type function child))
        (lambda ()
          (loop
            (let ((batch (funcall child)))
              (unless batch (return nil))
              (let* ((n (batch-count batch))
                     (before (key-table-count table))
                     (gids (key-table-map-batch table (coerce (batch-columns batch) 'list) n
                                                (make-index-vector n) t))
                     (idx (make-index-vector n))
                     (m 0)
                     (next before))
                (declare (type fixnum m next))
                (dotimes (i n)
                  (when (= (aref gids i) next)
                    (setf (aref idx m) i)
                    (incf m) (incf next)))
                (when (>= (- (key-table-count table) before) 1)
                  (charge-memory (* (- (key-table-count table) before) (row-footprint (* 2 width)))))
                (cond ((= m n) (return batch))
                      ((plusp m) (return (batch-gather batch idx m))))))))))))

;;; ------------------------------------------------------------------
;;; Hash join

(defstruct join-build
  "The hashed (build) input of a hash join."
  (table nil)                            ; KEY-TABLE of the normalized keys
  (first-row (make-index-vector 0) :type index-vector)   ; per group: first build row
  (next-row (make-index-vector 0) :type index-vector)    ; per build row: next row, or -1
  (batch nil))                           ; all build rows as one BATCH

(defun join-key-normalizers (exprs other-exprs)
  "Per key: NIL (identity) or the function normalizing values of the key
expression for comparison with the other side (see HASH-KEY-NORMALIZER),
and the vector kind of normalized keys."
  (loop for a in exprs
        for b in other-exprs
        collect (let ((norm (hash-key-normalizer (bexpr-type a) (bexpr-type b))))
                  (multiple-value-bind (nl nr kind) (comparison-normalizers (bexpr-type a) (bexpr-type b))
                    (declare (ignore nl nr))
                    (cons (if (eq norm #'identity) nil norm)
                          (type-vec-kind kind))))))

(defun join-key-vecs (kernels normalizers batch)
  "Normalized key VECs of BATCH, and an index vector of the rows having a
NULL key (or NIL)."
  (let* ((n (batch-count batch))
         (null-rows nil))
    (values
     (loop for kernel in kernels
           for (norm . kind) in normalizers
           collect (let ((vec (funcall (the function kernel) batch)))
                     (when (vec-has-nulls-p vec n)
                       (unless null-rows (setf null-rows (make-array n :element-type 'bit :initial-element 0)))
                       (dotimes (i n)
                         (when (eq (vec-ref vec i) +null+) (setf (sbit null-rows i) 1))))
                     (if norm
                         (build-vec kind n (lambda (i)
                                             (let ((v (vec-ref vec i)))
                                               (if (eq v +null+) +null+ (funcall (the function norm) v)))))
                         vec)))
     null-rows)))

(defun concatenate-batches (batches kinds)
  "One BATCH holding the rows of BATCHES in order."
  (let ((total (reduce #'+ batches :key #'batch-count)))
    (make-batch total
                (let ((columns (make-array (length kinds))))
                  (dotimes (k (length kinds) columns)
                    (setf (svref columns k)
                          (vec-concatenate (mapcar (lambda (b) (svref (batch-columns b) k)) batches)
                                           (svref kinds k) total)))))))

(defun build-join-input (open-build kernels normalizers kinds)
  "Drain the build input and hash it on its normalized keys."
  (declare (type function open-build))
  (let ((batches '())
        (child (funcall open-build)))
    (declare (type function child))
    (loop for b = (funcall child)
          while b
          do (charge-memory (* (batch-count b) (row-footprint (+ 3 (length kinds)))))
             (push b batches))
    (let* ((batch (concatenate-batches (nreverse batches) kinds))
           (n (batch-count batch))
           (table (make-key-table (length kernels) (max 16 n)))
           (gids (make-index-vector n))
           (next (make-array n :element-type 'fixnum :initial-element -1)))
      (multiple-value-bind (key-vecs null-rows) (join-key-vecs kernels normalizers batch)
        (key-table-map-batch table key-vecs n gids t)
        (let ((first (make-array (key-table-count table) :element-type 'fixnum :initial-element -1)))
          ;; Chain the rows of each key in input order.
          (loop for i from (1- n) downto 0
                unless (and null-rows (= 1 (sbit null-rows i)))
                  do (let ((g (aref gids i)))
                       (setf (aref next i) (aref first g)
                             (aref first g) i)))
          (make-join-build :table table :first-row first :next-row next :batch batch))))))

(defun make-join-build-provider (build-node open-build build-keys probe-keys)
  "Function returning the JOIN-BUILD of BUILD-NODE's rows: built on first
use, and only once when the build input is invariant (otherwise rebuilt by
every call, e.g. per execution of a correlated subquery)."
  (let ((kernels (mapcar #'compile-vexpr build-keys))
        (normalizers (join-key-normalizers build-keys probe-keys))
        (kinds (output-kinds build-node))
        (invariant (plan-invariant-p build-node))
        (cached nil))
    (lambda ()
      (if (and invariant cached)
          cached
          (let ((build (build-join-input open-build kernels normalizers kinds)))
            (when invariant (setf cached build))
            build)))))

(defun make-batch-hash-join (node open-probe build-provider &optional row-cell)
  "Batch opener of a hash join probing the JOIN-BUILD returned by
BUILD-PROVIDER with the batches of OPEN-PROBE. Output rows of one probe row
follow each other; for LEFT joins a probe row without match is padded with
NULLs."
  (declare (type function open-probe build-provider))
  (let* ((build-left (eq (pp-hash-join-build node) :left))
         (kind (pp-hash-join-kind node))
         (outer (eq kind :left))
         (probe-keys (if build-left (pp-hash-join-right-keys node) (pp-hash-join-left-keys node)))
         (build-keys (if build-left (pp-hash-join-left-keys node) (pp-hash-join-right-keys node)))
         (kernels (mapcar #'compile-vexpr probe-keys))
         (normalizers (join-key-normalizers probe-keys build-keys))
         (residual (and (pp-hash-join-residual node) (compile-vexpr (pp-hash-join-residual node)))))
    (lambda ()
      (let ((build nil)
            (probe (funcall open-probe))
            (batch nil) (n 0) (gids nil) (i 0) (chain -2)
            (row-had-pair nil)
            (matched #())
            (counter (join-row-counter row-cell)))
        (declare (type function probe counter) (type fixnum n i chain)
                 (type simple-vector matched))
        (labels ((assemble (pidx bidx m)
                   ;; Output batch of M (probe row, build row) pairs.
                   (let ((probe-cols (map 'simple-vector (lambda (v) (and v (vec-gather v pidx m)))
                                          (batch-columns batch)))
                         (build-cols (map 'simple-vector (lambda (v) (vec-gather v bidx m))
                                          (batch-columns (join-build-batch build)))))
                     (make-batch m (if build-left
                                       (concatenate 'simple-vector build-cols probe-cols)
                                       (concatenate 'simple-vector probe-cols build-cols)))))
                 (next-probe-batch ()
                   (setf batch (funcall probe))
                   (when batch
                     (setf n (batch-count batch) i 0 chain -2)
                     (multiple-value-bind (key-vecs null-rows) (join-key-vecs kernels normalizers batch)
                       (setf gids (key-table-map-batch (join-build-table build) key-vecs n
                                                       (make-index-vector n) nil))
                       (when null-rows
                         (dotimes (r n)
                           (when (= 1 (sbit null-rows r)) (setf (aref gids r) -1)))))
                     t))
                 (fill-pairs ()
                   ;; Up to a batch of candidate pairs; for LEFT joins without a
                   ;; residual, unmatched probe rows become (row, -1) pairs.
                   (let ((pidx (make-index-vector +batch-size+))
                         (bidx (make-index-vector +batch-size+))
                         (finished '())
                         (m 0)
                         (first-row (join-build-first-row build))
                         (next-row (join-build-next-row build)))
                     (declare (type fixnum m) (type index-vector first-row next-row gids))
                     (loop while (and (< m +batch-size+) (< i n))
                           do (when (= chain -2)
                                (let ((g (aref gids i)))
                                  (setf chain (if (< g 0) -1 (aref first-row g))
                                        row-had-pair nil)))
                              (loop while (and (>= chain 0) (< m +batch-size+))
                                    do (setf (aref pidx m) i (aref bidx m) chain
                                             row-had-pair t)
                                       (incf m)
                                       (setf chain (aref next-row chain)))
                              (when (< chain 0)
                                (when outer
                                  (if residual
                                      (push i finished)
                                      (unless row-had-pair
                                        (if (< m +batch-size+)
                                            (progn (setf (aref pidx m) i (aref bidx m) -1)
                                                   (incf m))
                                            (return)))))
                                (incf i)
                                (setf chain -2)))
                     (values pidx bidx m (nreverse finished))))
                 (apply-residual (pidx bidx m finished)
                   ;; Keep the pairs satisfying the residual; pad the finished
                   ;; probe rows of LEFT joins that kept no pair.
                   (let* ((pairs (assemble pidx bidx m))
                          (keep (if (plusp m)
                                    (vec-data (funcall (the function residual) pairs))
                                    #()))
                          (opidx (make-index-vector (+ m (length finished))))
                          (obidx (make-index-vector (+ m (length finished))))
                          (k 0))
                     (declare (type fixnum k) (type simple-vector keep))
                     (dotimes (j m)
                       (when (eq (svref keep j) t)
                         (setf (aref opidx k) (aref pidx j) (aref obidx k) (aref bidx j))
                         (incf k)
                         (when outer (setf (svref matched (aref pidx j)) t))))
                     (dolist (r finished)
                       (unless (svref matched r)
                         (setf (aref opidx k) r (aref obidx k) -1)
                         (incf k)))
                     (values opidx obidx k))))
          (declare (ignorable #'apply-residual))
          (lambda ()
            (unless build (setf build (funcall build-provider)))
            (loop
              (when (or (null batch) (>= i n))
                (unless (next-probe-batch) (return nil))
                (when (and outer residual) (setf matched (make-array n :initial-element nil))))
              (multiple-value-bind (pidx bidx m finished) (fill-pairs)
                (multiple-value-bind (pidx bidx m)
                    (if residual (apply-residual pidx bidx m finished) (values pidx bidx m))
                  (when (plusp m)
                    (dotimes (k m) (funcall counter))
                    (return (assemble pidx bidx m))))))))))))

(defmethod compile-batch-operator ((node pp-hash-join))
  (destructuring-bind (left right) (pnode-children node)
    (let* ((build-left (eq (pp-hash-join-build node) :left))
           (build-node (if build-left left right))
           (probe-node (if build-left right left)))
      (make-batch-hash-join
       node
       (compile-batch-operator probe-node)
       (make-join-build-provider build-node (compile-batch-operator build-node)
                                 (if build-left (pp-hash-join-left-keys node) (pp-hash-join-right-keys node))
                                 (if build-left (pp-hash-join-right-keys node) (pp-hash-join-left-keys node)))))))

;;; ------------------------------------------------------------------
;;; Entry point

(defun compile-vectorized-plan (node)
  "Row opener running the physical plan NODE on the batch executor."
  (batches-to-rows-opener (compile-batch-operator node)))
