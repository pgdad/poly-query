;;;; voperators.lisp — vectorized (batch-at-a-time) physical operators.
;;;;
;;;; COMPILE-BATCH-OPERATOR turns a physical plan node into a *batch opener*:
;;;; a function of no arguments returning a fresh iterator that yields
;;;; BATCHes (vectors.lisp) or NIL at the end. Scans, filters, projections,
;;;; limits, UNION ALL, hash aggregation, DISTINCT and hash joins are vectorized; every
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

(defun make-batch-scan (node &key ranges lazy)
  "Batch opener of a TableScan. RANGES, when given, is a function returning
the next (segment start end) range to read or NIL (parallel morsels);
otherwise all unskipped segments are read in order. With LAZY, batches of
column-layout segments are lazy (see SCAN-SOURCE)."
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
                (return (prog1 (if (and lazy (null (segment-rows seg)))
                                   (make-lazy-scan-batch seg column-indexes kinds pos stop)
                                   (segment-batch seg column-indexes kinds pos stop))
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

(defmethod compile-batch-operator ((node pp-union-all))
  ;; The branches' batches one branch after another; every branch already
  ;; produces the compound's column types.
  (concatenating-opener (mapcar #'compile-batch-operator (pnode-children node))))

;;; ------------------------------------------------------------------
;;; Errors in row order
;;;
;;; Kernels evaluate an expression for a whole batch before the next one, so
;;; when several rows would fail with different errors, the vectorized order
;;; could report another error than the row executor (which finishes all
;;; expressions of a row before the next row). When a kernel signals a data
;;; error, the batch is therefore replayed row by row with the row
;;; implementation of the operator's expressions, and the first error in row
;;; order is signalled (the kernel's own error if the replay succeeds).

(defparameter *data-error-codes*
  '("NUMERIC_OVERFLOW" "DIVISION_BY_ZERO" "CONVERSION_ERROR" "INVALID_ARGUMENT"
    "SUBQUERY_CARDINALITY"))

(defun make-row-order-guard (exprs)
  "Function (batch thunk) calling THUNK; a data error it signals is replaced
by the first error of evaluating EXPRS row by row over BATCH."
  (let ((fns nil))
    (lambda (batch thunk)
      (declare (type function thunk))
      (handler-case (funcall thunk)
        (pq-error (e)
          (when (member (pq-error-code e) *data-error-codes* :test #'string=)
            (unless fns (setf fns (mapcar #'compile-bexpr exprs)))
            (dotimes (i (batch-count batch))
              (let ((row (batch-row batch i)))
                (dolist (f fns) (funcall (the function f) row)))))
          (error e))))))

;;; ------------------------------------------------------------------
;;; Filter, projection, limit

(defun make-batch-filter (open-child predicate)
  (let ((filter (or (and (native-kernels-enabled-p) (compile-native-filter predicate))
                    (let ((kernel (compile-vexpr predicate))
                          (guard (make-row-order-guard (list predicate))))
                      (declare (type function kernel guard))
                      (lambda (batch)
                        (filter-batch batch (funcall guard batch
                                                     (lambda () (funcall kernel batch)))))))))
    (declare (type function open-child filter))
    (lambda ()
      (let ((child (funcall open-child)))
        (declare (type function child))
        (lambda ()
          (loop
            (let ((batch (funcall child)))
              (unless batch (return nil))
              (let ((out (funcall filter batch)))
                (when out (return out))))))))))

(defmethod compile-batch-operator ((node pp-filter))
  (let ((child (pnode-child node))
        (predicate (pp-filter-predicate node)))
    (cond ((never-true-p predicate) (lambda () (lambda () nil)))
          ((and (pp-table-scan-p child) (make-native-scan-filter child predicate)))
          (t (make-batch-filter (compile-batch-operator child) predicate)))))

(defun make-batch-project (open-child exprs)
  (let ((kernels (map 'simple-vector #'compile-vexpr exprs))
        (guard (make-row-order-guard exprs)))
    (declare (type function open-child guard))
    (lambda ()
      (let ((child (funcall open-child)))
        (declare (type function child))
        (lambda ()
          (let ((batch (funcall child)))
            (when batch
              (make-batch (batch-count batch)
                          (funcall guard batch
                                   (lambda ()
                                     (map 'simple-vector (lambda (k) (funcall (the function k) batch))
                                          kernels)))))))))))

(defmethod compile-batch-operator ((node pp-project))
  (make-batch-project (compile-batch-operator (pnode-child node)) (pp-project-exprs node)))

(defmethod compile-batch-operator ((node pp-limit))
  (let ((child (pnode-child node)))
    (if (pp-project-p child)
        ;; LIMIT commutes with a projection (one output row per input row):
        ;; limiting first projects only the rows the row executor would.
        (make-batch-project (compile-batch-operator
                             (make-pp-limit :children (pnode-children child)
                                            :columns (pnode-columns (pnode-child child))
                                            :limit (pp-limit-limit node)
                                            :offset (pp-limit-offset node)))
                            (pp-project-exprs child))
        (compile-batch-limit node))))

(defun compile-batch-limit (node)
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

(defun make-aggregate-consumer (node &key track-positions)
  "(values new-state consume lazy prepare) for vectorized aggregation of NODE:
(NEW-STATE [expected-groups]) creates an empty GROUP-STATE, (CONSUME state batch [base])
aggregates one input batch (whose first row has input position BASE) into
it; LAZY is true when CONSUME also accepts lazy scan batches (native
kernels, see GROUP-STATE-CONSUME-LAZY). (PREPARE batch) returns the key and
argument VECs of a batch, i.e. CONSUME's work before GROUP-STATE-CONSUME
(parallel.lisp aggregates them elsewhere). Kernels are compiled once per
call."
  (let* ((keys (pp-hash-aggregate-group-by node))
         (aggs (pp-hash-aggregate-aggregates node))
         (key-kernels (mapcar #'compile-vexpr keys))
         (arg-kernels (mapcar (lambda (a) (and (b-agg-args a) (compile-vexpr (first (b-agg-args a)))))
                              aggs))
         (key-kinds (mapcar (lambda (k) (type-vec-kind (bexpr-type k))) keys))
         (native (native-kernels-enabled-p))
         (lazy-columns nil)
         (lazy (and native
                    (multiple-value-bind (ok columns) (lazy-aggregation-columns keys aggs)
                      (setf lazy-columns columns)
                      ok)))
         (guard (make-row-order-guard (append keys (mapcan (lambda (a) (copy-list (b-agg-args a)))
                                                           aggs))))
         (prepare (lambda (batch)
                    (batch-materialize batch)
                    (funcall (the function guard) batch
                             (lambda ()
                               (values (mapcar (lambda (k) (funcall (the function k) batch)) key-kernels)
                                       (mapcar (lambda (k) (and k (funcall (the function k) batch)))
                                               arg-kernels)))))))
    (values
     (lambda (&optional (expected 16))
       (make-group-state key-kinds aggs track-positions native expected))
     (lambda (gs batch &optional (base 0))
       (let ((n (batch-count batch)))
         (if (batch-source batch)
             (group-state-consume-lazy gs batch lazy-columns)
             (multiple-value-bind (key-vecs arg-vecs) (funcall prepare batch)
               (group-state-consume gs key-vecs arg-vecs n base)))
         (group-state-charge gs)))
     lazy
     prepare)))

(defun group-state-charge (gs)
  "Charge the groups GS added since the last charge to the memory budget."
  (let ((groups (group-state-count gs))
        (charged (group-state-charged gs)))
    (when (>= (- groups charged) 1024)
      (charge-memory (* (- groups charged)
                        (row-footprint (* 4 (+ (if (group-state-table gs)
                                                   (key-table-width (group-state-table gs))
                                                   0)
                                               (length (group-state-aggs gs)))))))
      (setf (group-state-charged gs) groups))))

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

(defun make-batch-aggregate (child node)
  "Batch opener of the HashAggregate NODE over its input CHILD (a plan node)."
  (multiple-value-bind (new-state consume lazy) (make-aggregate-consumer node)
    (declare (type function new-state consume))
    (let ((open-child (if (and lazy (pp-table-scan-p child))
                          (make-batch-scan child :lazy t)
                          (compile-batch-operator child))))
      (declare (type function open-child))
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
            (funcall (the function output))))))))

(defmethod compile-batch-operator ((node pp-hash-aggregate))
  (make-batch-aggregate (pnode-child node) node))

;;; DISTINCT streams: a row is emitted when its key tuple is seen first.
(defmethod compile-batch-operator ((node pp-hash-distinct))
  (let ((open-child (compile-batch-operator (pnode-child node)))
        (width (length (pnode-columns node)))
        (native (native-kernels-enabled-p)))
    (declare (type function open-child))
    (lambda ()
      (let ((child (funcall open-child))
            (table (make-key-table width 16 (coerce (output-kinds node) 'list) native)))
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
;;; Joins
;;;
;;; All three join algorithms share one driver: the rows of a materialized
;;; *build* input are paired with the rows of each batch of the streamed
;;; *probe* input by an algorithm-specific pair generator (hash chains,
;;; merging of sorted runs, or all pairs). The driver gathers the (probe row,
;;; build row) index pairs into output batches, evaluates the residual
;;; condition on them and, for LEFT joins, pads the probe rows left without
;;; a qualifying pair with NULLs.

(defstruct join-build
  "The materialized build input of a join."
  (batch nil)                            ; all build rows as one BATCH
  ;; hash joins
  (table nil)                            ; KEY-TABLE of the normalized keys
  (first-row (make-index-vector 0) :type index-vector)   ; per group: first build row
  (next-row (make-index-vector 0) :type index-vector)    ; per build row: next row, or -1
  ;; merge joins
  (keys '())                             ; normalized key VECs
  (perm (make-index-vector 0) :type index-vector))       ; rows with non-NULL keys, sorted

(defun join-key-normalizers (exprs other-exprs)
  "Per key: (normalizer . kind . compare-type): NIL (identity) or the function
normalizing values of the key expression for comparison with the other side
(see HASH-KEY-NORMALIZER), the vector kind and the type of normalized keys."
  (loop for a in exprs
        for b in other-exprs
        collect (let ((norm (hash-key-normalizer (bexpr-type a) (bexpr-type b))))
                  (multiple-value-bind (nl nr kind) (comparison-normalizers (bexpr-type a) (bexpr-type b))
                    (declare (ignore nl nr))
                    (list* (if (eq norm #'identity) nil norm)
                           (type-vec-kind kind)
                           kind)))))

(defun join-key-vecs (kernels normalizers batch)
  "Normalized key VECs of BATCH, and a bitmap of the rows having a NULL key
(or NIL)."
  (let* ((n (batch-count batch))
         (null-rows nil))
    (values
     (loop for kernel in kernels
           for (norm kind) in normalizers
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

(defun concatenate-batches (batches kinds &optional (threads 1))
  "One BATCH holding the rows of BATCHES in order (the columns of many rows
concatenated by up to THREADS threads)."
  (let* ((total (reduce #'+ batches :key #'batch-count))
         (width (length kinds))
         (columns (make-array width)))
    (flet ((column (k)
             (setf (svref columns k)
                   (vec-concatenate (mapcar (lambda (b) (svref (batch-columns b) k)) batches)
                                    (svref kinds k) total))))
      (if (and (> threads 1) (> width 1) (>= total 65536))
          (let ((workers (min threads width)))
            (run-in-threads
             (loop for w below workers
                   collect (let ((w w))
                             (lambda ()
                               (loop for k from w below width by workers do (column k)))))))
          (dotimes (k width) (column k))))
    (make-batch total columns)))

(defun make-build-provider (build-node open-build prepare)
  "Function returning the JOIN-BUILD of BUILD-NODE's rows, made by PREPARE
from the materialized batch: built on first use, and only once when the build
input is invariant (otherwise rebuilt per call, e.g. per execution of a
correlated subquery)."
  (declare (type function prepare))
  (let ((kinds (output-kinds build-node))
        (invariant (plan-invariant-p build-node))
        (cached nil))
    (lambda ()
      (if (and invariant cached)
          cached
          (let ((build (funcall prepare (drain-batches open-build kinds))))
            (when invariant (setf cached build))
            build)))))

(defun join-key-comparator (vecs-a vecs-b normalizers)
  "Function (i j) -> -1/0/1 comparing the normalized keys of row I (VECS-A)
and row J (VECS-B)."
  (let ((comparators (mapcar (lambda (a b norm)
                               (make-key-comparator a b (cddr norm) nil nil))
                             vecs-a vecs-b normalizers)))
    (if (= (length comparators) 1)
        (first comparators)
        (lambda (i j)
          (dolist (cmp comparators 0)
            (let ((c (funcall (the function cmp) i j)))
              (declare (type fixnum c))
              (unless (zerop c) (return c))))))))

(defun sorted-key-permutation (key-vecs null-rows normalizers n threads)
  "Rows [0, N) without NULL keys, stably sorted by their normalized keys."
  (let* ((cmp (join-key-comparator key-vecs key-vecs normalizers))
         (before (lambda (i j) (minusp (the fixnum (funcall (the function cmp) i j)))))
         (perm (make-index-vector (- n (if null-rows (count 1 null-rows) 0))))
         (m 0))
    (declare (type fixnum m))
    (dotimes (i n)
      (unless (and null-rows (= 1 (sbit null-rows i)))
        (setf (aref perm m) i)
        (incf m)))
    (if (> threads 1)
        (parallel-stable-sort perm before threads)
        (stable-sort perm before))))

(defun make-pair-join (open-probe build-provider make-generator
                       &key residual outer build-left row-cell)
  "Batch opener of the join driver. MAKE-GENERATOR is called with each probe
batch and the JOIN-BUILD; it returns a generator, a function returning
(values pidx bidx m finished unpaired done): up to a batch of M candidate
pairs, the probe rows completed in this call (FINISHED) and those of them
that had no candidate at all (UNPAIRED), and whether the batch is done.
RESIDUAL is a BEXPR over the output row; BUILD-LEFT puts the build columns
first."
  (declare (type function open-probe build-provider make-generator))
  (let ((residual (and residual (compile-vexpr residual))))
    (lambda ()
      (let ((build nil)
            (probe (funcall open-probe))
            (batch nil)
            (generator nil)
            (matched #())
            (counter (join-row-counter row-cell)))
        (declare (type function probe counter) (type simple-vector matched))
        (labels ((assemble (pidx bidx m)
                   ;; Output batch of M (probe row, build row) pairs.
                   (let ((probe-cols (map 'simple-vector (lambda (v) (and v (vec-gather v pidx m)))
                                          (batch-columns batch)))
                         (build-cols (map 'simple-vector (lambda (v) (vec-gather v bidx m))
                                          (batch-columns (join-build-batch build)))))
                     (make-batch m (if build-left
                                       (concatenate 'simple-vector build-cols probe-cols)
                                       (concatenate 'simple-vector probe-cols build-cols)))))
                 (qualify (pidx bidx m finished unpaired)
                   ;; The pairs to output: without a residual all candidates
                   ;; (plus padded unpaired rows of LEFT joins); with one, those
                   ;; satisfying it (plus padded finished rows that kept none).
                   (let* ((pads (if outer (if residual finished unpaired) '()))
                          (keep (and residual (plusp m)
                                     (vec-data (funcall (the function residual)
                                                        (assemble pidx bidx m)))))
                          (opidx (make-index-vector (+ m (length pads))))
                          (obidx (make-index-vector (+ m (length pads))))
                          (k 0))
                     (declare (type fixnum k))
                     (dotimes (j m)
                       (when (or (null residual) (eq (svref keep j) t))
                         (setf (aref opidx k) (aref pidx j) (aref obidx k) (aref bidx j))
                         (incf k)
                         (when (and outer residual) (setf (svref matched (aref pidx j)) t))))
                     (dolist (r pads)
                       (unless (and residual (svref matched r))
                         (setf (aref opidx k) r (aref obidx k) -1)
                         (incf k)))
                     (values opidx obidx k))))
          (lambda ()
            (unless build (setf build (funcall build-provider)))
            (loop
              (unless generator
                (setf batch (funcall probe))
                (unless batch (return nil))
                (setf generator (funcall make-generator batch build))
                (when (and outer residual)
                  (setf matched (make-array (batch-count batch) :initial-element nil))))
              (multiple-value-bind (pidx bidx m finished unpaired done)
                  (funcall (the function generator))
                (when done (setf generator nil))
                (multiple-value-bind (pidx bidx m) (qualify pidx bidx m finished unpaired)
                  (when (plusp m)
                    (funcall counter m)
                    (return (assemble pidx bidx m))))))))))))

(defmacro with-pair-buffers ((pidx bidx m finished unpaired) &body body)
  "Bind fresh pair buffers for a generator call; BODY fills them."
  `(let ((,pidx (make-index-vector +batch-size+))
         (,bidx (make-index-vector +batch-size+))
         (,m 0)
         (,finished '())
         (,unpaired '()))
     (declare (type fixnum ,m) (ignorable ,finished ,unpaired))
     ,@body))

;;; Hash join: the build rows of each key are chained in input order.

(defun prepare-hash-build (kernels normalizers)
  (let ((native (native-kernels-enabled-p)))
    (lambda (batch)
      (let* ((n (batch-count batch))
             (table (make-key-table (length kernels) (max 16 n) (mapcar #'second normalizers) native))
             (gids (make-index-vector n))
             (next (make-array n :element-type 'fixnum :initial-element -1)))
        (multiple-value-bind (key-vecs null-rows) (join-key-vecs kernels normalizers batch)
          (key-table-map-batch table key-vecs n gids t)
          (let ((first (make-array (key-table-count table) :element-type 'fixnum :initial-element -1)))
            (loop for i from (1- n) downto 0
                  unless (and null-rows (= 1 (sbit null-rows i)))
                    do (let ((g (aref gids i)))
                         (setf (aref next i) (aref first g)
                               (aref first g) i)))
            (make-join-build :table table :first-row first :next-row next :batch batch)))))))

(defun make-join-build-provider (build-node open-build build-keys probe-keys)
  "Build provider of a hash join (see MAKE-BUILD-PROVIDER)."
  (make-build-provider build-node open-build
                       (prepare-hash-build (mapcar #'compile-vexpr build-keys)
                                           (join-key-normalizers build-keys probe-keys))))

(defun hash-pair-generator (kernels normalizers)
  (lambda (batch build)
    (let* ((n (batch-count batch))
           (gids (multiple-value-bind (key-vecs null-rows) (join-key-vecs kernels normalizers batch)
                   (let ((gids (key-table-map-batch (join-build-table build) key-vecs n
                                                    (make-index-vector n) nil)))
                     (when null-rows
                       (dotimes (r n)
                         (when (= 1 (sbit null-rows r)) (setf (aref gids r) -1))))
                     gids)))
           (first-row (join-build-first-row build))
           (next-row (join-build-next-row build))
           (i 0) (chain -2) (had-pair nil))
      (declare (type fixnum n i chain) (type index-vector gids first-row next-row))
      (lambda ()
        (with-pair-buffers (pidx bidx m finished unpaired)
          (loop while (and (< m +batch-size+) (< i n))
                do (when (= chain -2)
                     (let ((g (aref gids i)))
                       (setf chain (if (< g 0) -1 (aref first-row g))
                             had-pair nil)))
                   (loop while (and (>= chain 0) (< m +batch-size+))
                         do (setf (aref pidx m) i (aref bidx m) chain had-pair t)
                            (incf m)
                            (setf chain (aref next-row chain)))
                   (when (< chain 0)
                     (push i finished)
                     (unless had-pair (push i unpaired))
                     (incf i)
                     (setf chain -2)))
          (values pidx bidx m finished unpaired (>= i n)))))))

(defun make-batch-hash-join (node open-probe build-provider &optional row-cell)
  "Batch opener of a hash join probing the JOIN-BUILD returned by
BUILD-PROVIDER with the batches of OPEN-PROBE."
  (let* ((build-left (eq (pp-hash-join-build node) :left))
         (probe-keys (if build-left (pp-hash-join-right-keys node) (pp-hash-join-left-keys node)))
         (build-keys (if build-left (pp-hash-join-left-keys node) (pp-hash-join-right-keys node))))
    (make-pair-join open-probe build-provider
                    (hash-pair-generator (mapcar #'compile-vexpr probe-keys)
                                         (join-key-normalizers probe-keys build-keys))
                    :residual (pp-hash-join-residual node)
                    :outer (eq (pp-hash-join-kind node) :left)
                    :build-left build-left
                    :row-cell row-cell)))

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

;;; Sort-merge join: both inputs are materialized and their rows with
;;; non-NULL keys sorted; each left row is paired with the run of right rows
;;; having an equal key.

(defun single-batch-opener (open kinds)
  "Batch opener yielding all rows of OPEN as one batch."
  (lambda ()
    (let ((done nil))
      (lambda ()
        (unless done
          (setf done t)
          (drain-batches open kinds))))))

(defun merge-pair-generator (kernels normalizers threads)
  (lambda (batch build)
    (multiple-value-bind (left-keys null-rows) (join-key-vecs kernels normalizers batch)
      (let* ((n (batch-count batch))
             (left (sorted-key-permutation left-keys null-rows normalizers n threads))
             (right (join-build-perm build))
             (nl (length left)) (nr (length right))
             (cmp-lr (join-key-comparator left-keys (join-build-keys build) normalizers))
             (cmp-rr (join-key-comparator (join-build-keys build) (join-build-keys build) normalizers))
             (li 0) (j 0) (gs 0) (ge 0) (k 0) (emitting nil)
             (null-key-rows (and null-rows
                                 (loop for i below n when (= 1 (sbit null-rows i)) collect i))))
        (declare (type index-vector left right) (type fixnum n nl nr li j gs ge k)
                 (type function cmp-lr cmp-rr))
        (lambda ()
          (with-pair-buffers (pidx bidx m finished unpaired)
            ;; Rows with a NULL key never match.
            (setf finished null-key-rows unpaired null-key-rows null-key-rows '())
            (loop while (< m +batch-size+)
                  do (cond
                       (emitting
                        (let ((row (aref left li)))
                          (loop while (and (< k ge) (< m +batch-size+))
                                do (setf (aref pidx m) row (aref bidx m) (aref right k))
                                   (incf m) (incf k))
                          (when (>= k ge)
                            (push row finished)
                            (incf li)
                            (setf emitting nil))))
                       ((>= li nl) (return))
                       (t
                        (let ((row (aref left li)))
                          (if (and (< gs ge) (zerop (funcall cmp-lr row (aref right gs))))
                              ;; Same key as the previous left row: same run.
                              (setf emitting t k gs)
                              (progn
                                (setf j (max j ge))
                                (loop while (and (< j nr) (plusp (funcall cmp-lr row (aref right j))))
                                      do (incf j))
                                (if (and (< j nr) (zerop (funcall cmp-lr row (aref right j))))
                                    (progn
                                      (setf gs j ge (1+ j))
                                      (loop while (and (< ge nr)
                                                       (zerop (funcall cmp-rr (aref right gs) (aref right ge))))
                                            do (incf ge))
                                      (setf j ge emitting t k gs))
                                    (progn
                                      (push row finished)
                                      (push row unpaired)
                                      (incf li)))))))))
            (values pidx bidx m finished unpaired (and (>= li nl) (not emitting)))))))))

(defmethod compile-batch-operator ((node pp-merge-join))
  (destructuring-bind (left right) (pnode-children node)
    (let* ((lkeys (pp-merge-join-left-keys node))
           (rkeys (pp-merge-join-right-keys node))
           (right-kernels (mapcar #'compile-vexpr rkeys))
           (right-normalizers (join-key-normalizers rkeys lkeys))
           (threads (parallel-threads)))
      (make-pair-join
       (single-batch-opener (compile-batch-operator left) (output-kinds left))
       (make-build-provider
        right (compile-batch-operator right)
        (lambda (batch)
          (multiple-value-bind (keys null-rows) (join-key-vecs right-kernels right-normalizers batch)
            (make-join-build :batch batch :keys keys
                             :perm (sorted-key-permutation keys null-rows right-normalizers
                                                           (batch-count batch) threads)))))
       (merge-pair-generator (mapcar #'compile-vexpr lkeys) (join-key-normalizers lkeys rkeys) threads)
       :residual (pp-merge-join-residual node)
       :outer (eq (pp-merge-join-kind node) :left)))))

;;; Nested-loop join: every left row is paired with every right row; the
;;; whole join condition is the residual.

(defun nested-loop-pair-generator ()
  (lambda (batch build)
    (let ((n (batch-count batch))
          (nb (batch-count (join-build-batch build)))
          (i 0) (j 0))
      (declare (type fixnum n nb i j))
      (lambda ()
        (with-pair-buffers (pidx bidx m finished unpaired)
          (loop while (and (< m +batch-size+) (< i n))
                do (loop while (and (< j nb) (< m +batch-size+))
                         do (setf (aref pidx m) i (aref bidx m) j)
                            (incf m) (incf j))
                   (when (>= j nb)
                     (push i finished)
                     (when (zerop nb) (push i unpaired))
                     (incf i)
                     (setf j 0)))
          (values pidx bidx m finished unpaired (>= i n)))))))

(defmethod compile-batch-operator ((node pp-nested-loop-join))
  (destructuring-bind (left right) (pnode-children node)
    (make-pair-join
     (compile-batch-operator left)
     (make-build-provider right (compile-batch-operator right)
                          (lambda (batch) (make-join-build :batch batch)))
     (nested-loop-pair-generator)
     :residual (pp-nested-loop-join-condition node)
     :outer (eq (pp-nested-loop-join-kind node) :left))))

;;; ------------------------------------------------------------------
;;; Sorting: the input is materialized as one batch and a permutation of its
;;; row indexes is sorted (stably) with comparators reading the typed key
;;; columns directly.

(defun make-key-comparator (vec-a vec-b type descending nulls-first)
  "Function (i j) -> -1/0/1 ordering row I of VEC-A against row J of VEC-B
(two vectors of the same kind) for one ORDER BY key."
  (let ((data-a (vec-data vec-a)) (validity-a (vec-validity vec-a))
        (data-b (vec-data vec-b)) (validity-b (vec-validity vec-b))
        (null-order (if nulls-first -1 1))
        (sign (if descending -1 1)))
    (declare (type fixnum null-order sign)
             (type (or null simple-bit-vector) validity-a validity-b))
    (macrolet ((typed (element-type)
                 `(let ((data-a data-a) (data-b data-b))
                    (declare (type (simple-array ,element-type (*)) data-a data-b))
                    (lambda (i j)
                      (declare (type fixnum i j))
                      (let ((an (and validity-a (zerop (sbit validity-a i))))
                            (bn (and validity-b (zerop (sbit validity-b j)))))
                        (cond ((and an bn) 0)
                              (an null-order)
                              (bn (- null-order))
                              (t (let ((a (aref data-a i)) (b (aref data-b j)))
                                   (cond ((< a b) (- sign)) ((> a b) sign) (t 0))))))))))
      (cond
        ((and (typep data-a 'i64-vector) (typep data-b 'i64-vector)) (typed (signed-byte 64)))
        ((and (typep data-a 'f64-vector) (typep data-b 'f64-vector)) (typed double-float))
        (t
         ;; Generic values (and mixed representations, e.g. a NULL-typed
         ;; join key against an INT64 one).
         (let ((cmp (make-sort-key-comparator type descending nulls-first)))
           (declare (type function cmp))
           (lambda (i j)
             (declare (type fixnum i j))
             (funcall cmp (vec-ref vec-a i) (vec-ref vec-b j)))))))))

(defun make-row-order-predicate (batch-a batch-b keys)
  "Predicate (i j) -> T when row I of BATCH-A sorts strictly before row J of
BATCH-B under the ORDER BY KEYS ((pos type descending nulls-first) lists)."
  (let ((comparators (map 'simple-vector
                          (lambda (key)
                            (destructuring-bind (pos type descending nulls-first) key
                              (make-key-comparator (svref (batch-columns batch-a) pos)
                                                   (svref (batch-columns batch-b) pos)
                                                   type descending nulls-first)))
                          keys)))
    (if (= (length comparators) 1)
        (let ((cmp (svref comparators 0)))
          (declare (type function cmp))
          (lambda (i j) (minusp (the fixnum (funcall cmp i j)))))
        (lambda (i j)
          (loop for cmp across comparators
                for c of-type fixnum = (funcall (the function cmp) i j)
                do (cond ((< c 0) (return t))
                         ((> c 0) (return nil)))
                finally (return nil))))))

(defun make-index-sort-predicate (batch keys)
  (make-row-order-predicate batch batch keys))

(defun sorted-permutation (batch keys &optional (threads 1))
  "Row indexes of BATCH in ORDER BY KEYS order (stable)."
  (let* ((n (batch-count batch))
         (perm (identity-index-vector n))
         (words (radix-key-words batch keys threads)))
    (if words
        (let ((chunk-sort (lambda (chunk) (radix-sort-permutation chunk words))))
          (if (> threads 1)
              (parallel-stable-sort perm nil threads chunk-sort
                                    (lambda (src dst start mid end)
                                      (merge-runs-by-words src dst start mid end words)))
              (funcall chunk-sort perm)))
        (let ((before (make-index-sort-predicate batch keys)))
          (if (> threads 1)
              (parallel-stable-sort perm before threads)
              (stable-sort perm before))))))

;;; Radix sorting. When every ORDER BY key is an INT64-like or FLOAT64
;;; column, each key value maps to an unsigned 64-bit word whose order is
;;; the key's order (sign bit flipped; IEEE bits of doubles with negative
;;; values inverted, -0.0 as 0.0; complemented for DESC); a key with NULLs
;;; also gets a more significant word holding its NULL flag (NULL values
;;; get the value word 0, as they are equal). Rows then compare as their
;;; word sequences, and a stable LSD radix sort over the words, least
;;; significant first, yields exactly the stable comparison sort. Digits on
;;; which all rows agree are skipped.

(defconstant +radix-bits+ 11)
(defconstant +u64-mask+ #xFFFFFFFFFFFFFFFF)

(deftype u64-vector () '(simple-array (unsigned-byte 64) (*)))

(declaim (inline radix-word))
(defun radix-word (data i descending)
  "Order-preserving unsigned word of DATA[I]."
  (let ((w (etypecase data
             (i64-vector (logxor (logand (aref data i) +u64-mask+) #x8000000000000000))
             (f64-vector (let* ((d (aref data i))
                                (bits (logand (sb-kernel:double-float-bits (if (zerop d) 0d0 d))
                                              +u64-mask+)))
                           (if (logbitp 63 bits)
                               (logand (lognot bits) +u64-mask+)
                               (logior bits #x8000000000000000)))))))
    (declare (type (unsigned-byte 64) w))
    (if descending (logxor w +u64-mask+) w)))

(defun radix-key-words (batch keys &optional (threads 1))
  "Simple vector of U64-VECTORs (most significant first) of the row words
for sorting BATCH by KEYS ((pos type descending nulls-first) lists), or NIL
when some key is not a typed INT64-like/FLOAT64 column (or holds NaN). With
THREADS > 1, large batches are encoded by several threads."
  (let* ((n (batch-count batch))
         (specs
           ;; Per key: (data validity descending nulls-first words flags).
           (loop for (pos nil descending nulls-first) in keys
                 for vec = (svref (batch-columns batch) pos)
                 for data = (vec-data vec)
                 for validity = (vec-validity vec)
                 do (unless (or (typep data 'i64-vector)
                                (and (typep data 'f64-vector)
                                     (let ((data data))
                                       (declare (type f64-vector data))
                                       (loop for d across data always (= d d))))) ; no NaN
                      (return-from radix-key-words nil))
                 collect (list data validity descending nulls-first
                               (make-array n :element-type '(unsigned-byte 64))
                               (and validity (make-array n :element-type '(unsigned-byte 64)))))))
    (flet ((encode (start end)
             (declare (type fixnum start end))
             (loop for (data validity descending nulls-first words flags) in specs
                   do (let ((words words))
                        (declare (type u64-vector words))
                        (macrolet ((fill-words (type)
                                     `(let ((data data))
                                        (declare (type ,type data))
                                        (loop for i from start below end
                                              do (setf (aref words i) (radix-word data i descending))))))
                          (if (typep data 'i64-vector) (fill-words i64-vector) (fill-words f64-vector)))
                        (when validity
                          (let ((flags flags)
                                (null-flag (if nulls-first 0 1)))
                            (declare (type u64-vector flags) (type simple-bit-vector validity))
                            (loop for i from start below end
                                  do (if (zerop (sbit validity i))
                                         (setf (aref flags i) null-flag
                                               (aref words i) 0)
                                         (setf (aref flags i) (- 1 null-flag))))))))))
      (if (and (> threads 1) (>= n 65536))
          (run-in-threads
           (loop for k below threads
                 collect (let ((start (floor (* k n) threads))
                               (end (floor (* (1+ k) n) threads)))
                           (lambda () (encode start end)))))
          (encode 0 n)))
    (coerce (loop for (nil validity nil nil words flags) in specs
                  when validity collect flags
                  collect words)
            'simple-vector)))

(defun radix-pass (perm words perm2 words2 shift bits)
  "Stable counting sort of (PERM, WORDS) into (PERM2, WORDS2) by the digit of
BITS bits at SHIFT; returns NIL (and does nothing) if all digits are equal."
  (declare (type index-vector perm perm2) (type u64-vector words words2)
           (type (integer 0 63) shift) (type (integer 1 16) bits))
  (let* ((n (length perm))
         (buckets (ash 1 bits))
         (counts (make-array (1+ buckets) :element-type 'fixnum :initial-element 0)))
    (declare (type fixnum n buckets))
    (dotimes (i n)
      (incf (aref counts (1+ (ldb (byte bits shift) (aref words i))))))
    (when (= (aref counts (1+ (ldb (byte bits shift) (aref words 0)))) n)
      (return-from radix-pass nil))
    (loop for d from 1 to buckets
          do (incf (aref counts d) (aref counts (1- d))))
    (dotimes (i n t)
      (let* ((w (aref words i))
             (d (ldb (byte bits shift) w))
             (k (aref counts d)))
        (setf (aref perm2 k) (aref perm i)
              (aref words2 k) w
              (aref counts d) (1+ k))))))

(defun radix-sort-permutation (perm key-words)
  "PERM (row indexes) stably sorted by the row words KEY-WORDS (see
RADIX-KEY-WORDS); may return a new vector."
  (declare (type index-vector perm) (type simple-vector key-words))
  (let* ((n (length perm))
         (words (make-array n :element-type '(unsigned-byte 64)))
         (perm2 (make-index-vector n))
         (words2 (make-array n :element-type '(unsigned-byte 64))))
    (declare (type u64-vector words words2) (type index-vector perm2))
    (when (< n 2) (return-from radix-sort-permutation perm))
    (loop for k from (1- (length key-words)) downto 0
          do (let ((row-words (svref key-words k))
                   (all-or 0) (all-and +u64-mask+))
               (declare (type u64-vector row-words) (type (unsigned-byte 64) all-or all-and))
               (dotimes (i n)
                 (let ((w (aref row-words (aref perm i))))
                   (setf (aref words i) w
                         all-or (logior all-or w)
                         all-and (logand all-and w))))
               ;; Only digits containing bits that differ between rows matter.
               (let ((varying (logxor all-or all-and)))
                 (loop for shift from 0 below (integer-length varying) by +radix-bits+
                       do (when (and (plusp (ldb (byte +radix-bits+ shift) varying))
                                     (radix-pass perm words perm2 words2 shift
                                                 (min +radix-bits+ (- 64 shift))))
                            (rotatef perm perm2)
                            (rotatef words words2))))))
    perm))

(defun merge-runs-by-words (src dst start mid end key-words)
  "Stably merge the sorted runs SRC[START,MID) and SRC[MID,END) into DST,
comparing rows by their KEY-WORDS."
  (declare (type index-vector src dst) (type fixnum start mid end)
           (type simple-vector key-words))
  (flet ((before (a b)
           (declare (type fixnum a b))
           (loop for w across key-words
                 do (let ((x (aref (the u64-vector w) a))
                          (y (aref (the u64-vector w) b)))
                      (cond ((< x y) (return t))
                            ((> x y) (return nil))))
                 finally (return nil))))
    (declare (inline before))
    (let ((i start) (j mid) (k start))
      (declare (type fixnum i j k))
      (loop while (and (< i mid) (< j end))
            do (if (before (aref src j) (aref src i))
                   (progn (setf (aref dst k) (aref src j)) (incf j))
                   (progn (setf (aref dst k) (aref src i)) (incf i)))
               (incf k))
      (replace dst src :start1 k :start2 i :end2 mid)
      (replace dst src :start1 (+ k (- mid i)) :start2 j :end2 end))))

(defun drain-batches (open kinds)
  "All rows of the batch opener OPEN as one batch (charging memory)."
  (declare (type function open))
  (let ((child (funcall open))
        (batches '()))
    (declare (type function child))
    (loop for b = (funcall child)
          while b
          do (charge-memory (* (batch-count b) (row-footprint (length kinds))))
             (push b batches))
    (concatenate-batches (nreverse batches) kinds (parallel-threads))))

(defun permutation-batches (batch perm start end &optional (threads 1))
  "Iterator over the rows PERM[START..END) of BATCH, a batch at a time. With
THREADS > 1 and many rows, the batches are gathered in parallel up front."
  (declare (type fixnum start end) (type index-vector perm))
  (let ((pos start)
        (nbatches (ceiling (- end start) +batch-size+)))
    (declare (type fixnum pos))
    (flet ((gather (from)
             (let* ((stop (min end (+ from +batch-size+)))
                    (idx (subseq perm from stop)))
               (batch-gather batch idx (length idx)))))
      (if (and (> threads 1) (> nbatches 8))
          (let ((batches (make-array nbatches))
                (workers (min threads nbatches))
                (k 0))
            (declare (type fixnum k))
            (run-in-threads
             (loop for w below workers
                   collect (let ((w w))
                             (lambda ()
                               (loop for b from w below nbatches by workers
                                     do (setf (svref batches b)
                                              (gather (+ start (* b +batch-size+)))))))))
            (lambda ()
              (when (< k nbatches)
                (prog1 (svref batches k)
                  (setf (svref batches k) nil)
                  (incf k)))))
          (lambda ()
            (when (< pos end)
              (prog1 (gather pos)
                (setf pos (min end (+ pos +batch-size+))))))))))

(defmethod compile-batch-operator ((node pp-sort))
  (let ((open-child (compile-batch-operator (pnode-child node)))
        (kinds (output-kinds node))
        (keys (pp-sort-keys node))
        (threads (parallel-threads)))
    (lambda ()
      (let ((output nil))
        (lambda ()
          (unless output
            (let ((batch (drain-batches open-child kinds)))
              (check-interrupts)
              (setf output (permutation-batches batch (sorted-permutation batch keys threads)
                                                0 (batch-count batch) threads))))
          (funcall (the function output)))))))

(defun make-top-n-collector (keys keep kinds)
  "(values add finish) keeping the best KEEP rows under the ORDER BY KEYS of
the batches (of column KINDS) given to ADD, in order (ties keep input
order): the buffered rows are compacted to the best KEEP whenever they reach
twice that many, and once KEEP rows are known only rows sorting strictly
before the last of them are buffered. FINISH returns the best rows, sorted,
as one batch (or NIL)."
  (let ((buffer '()) (buffered 0) (best nil))
    (declare (type fixnum buffered))
    (flet ((compact ()
             (let* ((batch (concatenate-batches
                            (if best (cons best (nreverse buffer)) (nreverse buffer))
                            kinds))
                    (perm (sorted-permutation batch keys))
                    (n (min keep (batch-count batch))))
               (setf best (batch-gather batch perm n)
                     buffer '()
                     buffered 0))))
      (values
       (lambda (b)
         (unless (zerop keep)
           (when (and best (= (batch-count best) keep))
             (let ((before (make-row-order-predicate b best keys))
                   (last (1- keep))
                   (idx (make-index-vector (batch-count b)))
                   (m 0))
               (declare (type function before) (type fixnum m))
               (dotimes (i (batch-count b))
                 (when (funcall before i last)
                   (setf (aref idx m) i)
                   (incf m)))
               (setf b (cond ((zerop m) nil)
                             ((= m (batch-count b)) b)
                             (t (batch-gather b idx m))))))
           (when b
             (push b buffer)
             (incf buffered (batch-count b))
             (when (>= buffered (max +batch-size+ (* 2 keep)))
               (check-interrupts)
               (compact)))))
       (lambda ()
         (unless (zerop keep) (compact))
         best)))))

(defun top-n-output (best offset)
  "Iterator over the rows of the sorted batch BEST from OFFSET on."
  (if best
      (permutation-batches best (identity-index-vector (batch-count best))
                           (min offset (batch-count best))
                           (batch-count best))
      (lambda () nil)))

(defmethod compile-batch-operator ((node pp-top-n))
  ;; ORDER BY ... LIMIT: keep the best LIMIT+OFFSET rows (MAKE-TOP-N-COLLECTOR).
  (let* ((open-child (compile-batch-operator (pnode-child node)))
         (kinds (output-kinds node))
         (keys (pp-top-n-keys node))
         (limit (evaluate-limit-expr (pp-top-n-limit node) "LIMIT"))
         (offset (or (evaluate-limit-expr (pp-top-n-offset node) "OFFSET") 0))
         (keep (+ limit offset)))
    (declare (type function open-child))
    (lambda ()
      (let ((output nil))
        (lambda ()
          (unless output
            (multiple-value-bind (add finish) (make-top-n-collector keys keep kinds)
              (declare (type function add finish))
              (unless (zerop keep)
                (let ((child (funcall open-child)))
                  (declare (type function child))
                  (loop for b = (funcall child)
                        while b
                        do (funcall add b))))
              (setf output (top-n-output (funcall finish) offset))))
          (funcall (the function output)))))))

;;; ------------------------------------------------------------------
;;; Entry point

(defun compile-vectorized-plan (node)
  "Row opener running the physical plan NODE on the batch executor."
  (batches-to-rows-opener (compile-batch-operator node)))
