;;;; parallel.lisp — morsel-driven parallel execution (`threads` option).
;;;;
;;;; A *pipeline* is a chain of streaming batch operators (Filter, Project,
;;;; the probe side of HashJoin) over a TableScan. With `threads: N` > 1 the
;;;; vectorized executor runs a pipeline in N worker threads: the scanned
;;;; segments are cut into *morsels* (row ranges of +MORSEL-ROWS+), which the
;;;; workers claim one at a time, each running its own compiled copy of the
;;;; pipeline over the morsel. The shared state is read-only: tables, and the
;;;; hash tables of joins, which are built once before the workers start
;;;; (their build inputs may themselves run in parallel).
;;;;
;;;;  * Parallel scan (PARALLEL-GATHER): the output batches of each morsel are
;;;;    handed to the consumer in morsel order, so the result order equals
;;;;    the serial one. Workers run at most a window of morsels ahead of the
;;;;    consumer, bounding the buffered output.
;;;;  * Parallel aggregation (PARALLEL-AGGREGATE): every worker aggregates the
;;;;    morsels it claims into its own partial GROUP-STATE; the partial states
;;;;    are then merged (vaggregates.lisp).
;;;;
;;;; Errors in a worker stop the run and are re-signalled by the consumer.
;;;; Every run registers a query cleanup that stops and joins its workers,
;;;; so no thread outlives the query (also when a LIMIT stops reading early).
;;;; Pipelines whose expressions contain correlated subqueries or correlation
;;;; parameters run serially, as does everything inside subqueries.

(in-package #:polyquery)

(defvar *morsel-rows* nil
  "Rows per morsel; NIL means the environment variable POLYQUERY_MORSEL_ROWS
(used by tests to force many small morsels) or 16384.")

(defun morsel-rows ()
  (or *morsel-rows*
      (let ((env (sb-posix:getenv "POLYQUERY_MORSEL_ROWS")))
        (and env (ignore-errors (let ((n (parse-integer env))) (and (plusp n) n)))))
      16384))

(defun parallel-threads ()
  (if *parallel-disabled* 1 (execution-settings-threads *execution-settings*)))

;;; ------------------------------------------------------------------
;;; Pipelines

(defun parallel-safe-node-p (node)
  "True if NODE's expressions can be evaluated by independent workers: no
correlation parameters, and only subqueries evaluated once per query (their
result is shared, see QUERY-SHARED-VALUE)."
  (notany (lambda (e)
            (and e (bexpr-some (lambda (x)
                                 (or (b-param-p x)
                                     (and (subquery-op-p x) (not (uncorrelated-subquery-p x)))))
                               e)))
          (node-expressions node)))

(defun hash-join-probe-node (node)
  (if (eq (pp-hash-join-build node) :left)
      (second (pnode-children node))
      (first (pnode-children node))))

(defun hash-join-build-node (node)
  (if (eq (pp-hash-join-build node) :left)
      (first (pnode-children node))
      (second (pnode-children node))))

(defun pipeline-scan (node)
  "The TableScan feeding NODE through streaming operators, or NIL when NODE
is not a parallelizable pipeline."
  (typecase node
    (pp-table-scan node)
    ((or pp-filter pp-project)
     (and (parallel-safe-node-p node) (pipeline-scan (pnode-child node))))
    (pp-hash-join
     (and (parallel-safe-node-p node)
          (plan-invariant-p (hash-join-build-node node))
          (pipeline-scan (hash-join-probe-node node))))
    (t nil)))

(defun scan-morsels (scan)
  "Vector of the (segment start end) morsels of a TableScan."
  (let ((size (morsel-rows)))
    (coerce (loop for seg in (scan-segments scan)
                  nconc (loop for start from 0 below (segment-count seg) by size
                              collect (list seg start (min (segment-count seg) (+ start size)))))
            'simple-vector)))

(defstruct (pipeline-copy (:constructor make-pipeline-copy (opener cell)))
  "One worker's compiled pipeline; CELL holds the morsel its scan reads next."
  opener cell)

(defun compile-pipeline-copy (node builds cells &optional lazy)
  "Compile a private copy of the pipeline NODE. BUILDS and CELLS map the
pipeline's hash joins to their shared build providers and row counters.
LAZY makes a TableScan pipeline yield lazy batches."
  (let* ((cell (list nil))
         (opener
           (let ((*parallel-disabled* t))
             (labels ((compile-node (n)
                        (etypecase n
                          (pp-table-scan
                           (make-batch-scan n :ranges (lambda () (shiftf (car cell) nil))
                                              :lazy lazy))
                          (pp-filter
                           (or (and (pp-table-scan-p (pnode-child n))
                                    (make-native-scan-filter
                                     (pnode-child n) (pp-filter-predicate n)
                                     :ranges (lambda () (shiftf (car cell) nil))))
                               (make-batch-filter (compile-node (pnode-child n))
                                                  (pp-filter-predicate n))))
                          (pp-project (make-batch-project (compile-node (pnode-child n))
                                                          (pp-project-exprs n)))
                          (pp-hash-join (make-batch-hash-join n (compile-node (hash-join-probe-node n))
                                                              (cdr (assoc n builds))
                                                              (cdr (assoc n cells)))))))
               (compile-node node)))))
    (make-pipeline-copy opener cell)))

(defun pipeline-joins (node)
  (typecase node
    ((or pp-filter pp-project) (pipeline-joins (pnode-child node)))
    (pp-hash-join (cons node (pipeline-joins (hash-join-probe-node node))))
    (t '())))

(defun compile-pipeline-copies (node count &optional lazy)
  "(values copies providers): COUNT private copies of the pipeline NODE and
the shared build providers of its hash joins (to be forced before the
workers start). LAZY: see COMPILE-PIPELINE-COPY."
  (let* ((joins (pipeline-joins node))
         (builds (mapcar (lambda (j)
                           (let ((build-left (eq (pp-hash-join-build j) :left))
                                 (build-node (hash-join-build-node j)))
                             (cons j (make-join-build-provider
                                      build-node (compile-batch-operator build-node)
                                      (if build-left (pp-hash-join-left-keys j) (pp-hash-join-right-keys j))
                                      (if build-left (pp-hash-join-right-keys j) (pp-hash-join-left-keys j))))))
                         joins))
         (cells (mapcar (lambda (j) (cons j (make-row-cell))) joins))
         (shared (mapcar (lambda (b)
                           ;; Build once, on first use, then share.
                           (let ((provider (cdr b)) (value nil))
                             (cons (car b) (lambda () (or value (setf value (funcall provider)))))))
                         builds)))
    (values (coerce (loop repeat count collect (compile-pipeline-copy node shared cells lazy))
                    'simple-vector)
            (mapcar #'cdr shared))))

;;; ------------------------------------------------------------------
;;; Runs: workers, morsel dispatch, errors, cleanup

(defstruct (prun (:constructor make-prun (morsels)))
  (morsels #() :type simple-vector)
  (next 0 :type fixnum)                  ; next morsel to hand out
  (consumed 0 :type fixnum)              ; morsels taken by an ordered consumer
  (window nil)                           ; max morsels ahead of CONSUMED, or NIL
  (results #() :type simple-vector)
  (error nil)                            ; the error of the earliest failed morsel
  (error-morsel most-positive-fixnum :type fixnum)
  (stopped nil)
  (mutex (sb-thread:make-mutex :name "parallel run"))
  (cv (sb-thread:make-waitqueue :name "parallel run"))
  (threads '()))

(defun prun-fail (run condition &optional (morsel -1))
  "Record CONDITION, signalled while processing MORSEL (-1: outside any
morsel). The run reports the error of the earliest failed morsel, as a
serial execution would: morsels before it are still completed, later ones
are no longer started."
  (sb-thread:with-mutex ((prun-mutex run))
    (when (< morsel (prun-error-morsel run))
      (setf (prun-error run) condition
            (prun-error-morsel run) morsel))
    (sb-thread:condition-broadcast (prun-cv run))))

(defun prun-stop (run)
  "Stop the workers of RUN and wait for them to exit."
  (sb-thread:with-mutex ((prun-mutex run))
    (setf (prun-stopped run) t)
    (sb-thread:condition-broadcast (prun-cv run)))
  (loop for th = (pop (prun-threads run))
        while th
        do (sb-thread:join-thread th :default nil)))

(defun prun-claim (run)
  "Index of the next morsel for a worker, or NIL when the run is over."
  (sb-thread:with-mutex ((prun-mutex run))
    (loop
      (let ((next (prun-next run))
            (window (prun-window run)))
        (cond ((prun-stopped run) (return nil))
              ((>= next (length (prun-morsels run))) (return nil))
              ((>= next (prun-error-morsel run)) (return nil))
              ((or (null window) (< next (+ (prun-consumed run) window)))
               (setf (prun-next run) (1+ next))
               (return next))
              (t (timed-condition-wait (prun-cv run) (prun-mutex run) 0.1)))))))

(defun prun-start (run count body)
  "Start COUNT workers calling (BODY worker-index) with the query's dynamic
environment; register their shutdown as a query cleanup."
  (let ((ctx *query-context*)
        (settings *execution-settings*))
    (add-query-cleanup (lambda () (prun-stop run)))
    (setf (prun-threads run)
          (loop for w below count
                collect (let ((w w))
                          (sb-thread:make-thread
                           (lambda ()
                             (let ((*query-context* ctx)
                                   (*execution-settings* settings)
                                   (*parallel-disabled* t))
                               (sb-int:with-float-traps-masked
                                   (:overflow :invalid :divide-by-zero :inexact :underflow)
                                 (handler-case (funcall body w)
                                   (serious-condition (e) (prun-fail run e))))))
                           :name "polyquery-query-worker"))))))

(defun prun-raise (run)
  "Re-signal the error of a failed run in the consumer thread."
  (let ((e (prun-error run)))
    (when e
      (prun-stop run)
      (error e))))

(defun run-morsels (run copy fn)
  "Worker loop: claim morsels of RUN and call FN with the morsel index and
the iterator of the pipeline COPY opened on it, until the run is over or a
morsel fails."
  (declare (type function fn))
  (loop for m = (prun-claim run)
        while m
        do (handler-case
               (progn
                 (setf (car (pipeline-copy-cell copy)) (svref (prun-morsels run) m))
                 (funcall fn m (funcall (the function (pipeline-copy-opener copy)))))
             (serious-condition (e)
               (prun-fail run e m)
               (return)))))

;;; ------------------------------------------------------------------
;;; Parallel scan with ordered gather

(defun make-parallel-gather (node scan threads)
  "Batch opener running the pipeline NODE (over SCAN) in up to THREADS
workers, yielding the batches in serial order."
  (let ((morsel-count (length (scan-morsels scan)))
        (workers (min threads (length (scan-morsels scan)))))
    (multiple-value-bind (copies providers) (compile-pipeline-copies node workers)
      (lambda ()
        (mapc #'funcall providers)
        (let* ((run (make-prun (scan-morsels scan)))
               (k 0)
               (pending '()))
          (declare (type fixnum k))
          (setf (prun-results run) (make-array morsel-count :initial-element :pending)
                (prun-window run) (* 2 workers))
          (prun-start run workers
                      (lambda (w)
                        (run-morsels run (svref copies w)
                                     (lambda (m iter)
                                       (declare (type function iter))
                                       (let ((batches '()))
                                         (loop for b = (funcall iter)
                                               while b
                                               do (when (prun-stopped run) (return-from nil))
                                                  (charge-memory (* (batch-count b)
                                                                    (row-footprint (length (batch-columns b)))))
                                                  (push b batches))
                                         (sb-thread:with-mutex ((prun-mutex run))
                                           (setf (svref (prun-results run) m) (nreverse batches))
                                           (sb-thread:condition-broadcast (prun-cv run))))))))
          (lambda ()
            (loop
              (when pending (return (pop pending)))
              (when (>= k morsel-count) (return nil))
              (let ((ready nil))
                (sb-thread:with-mutex ((prun-mutex run))
                  (loop until (or (<= (prun-error-morsel run) k)
                                  (not (eq (svref (prun-results run) k) :pending)))
                        do (timed-condition-wait (prun-cv run) (prun-mutex run) 0.05)
                           (return))
                  (unless (or (<= (prun-error-morsel run) k)
                              (eq (svref (prun-results run) k) :pending))
                    (setf pending (svref (prun-results run) k)
                          (svref (prun-results run) k) nil
                          ready t)
                    (incf k)
                    (setf (prun-consumed run) k)
                    (sb-thread:condition-broadcast (prun-cv run))))
                ;; Morsels before K all succeeded: an error at K is the first
                ;; one in serial order.
                (when (<= (prun-error-morsel run) k)
                  (prun-raise run))
                (unless ready (check-interrupts))))))))))

;;; ------------------------------------------------------------------
;;; Parallel aggregation
;;;
;;; Workers aggregate the morsels they claim into private partial states,
;;; which are merged at the end. That suits few groups; with many groups
;;; every worker would build (and the merge re-insert) a table of nearly
;;; all groups. So after its first morsel a worker checks how many groups
;;; that morsel produced (the first worker to finish one decides for the
;;; run): beyond +PARTITION-GROUP-RATIO+ of its rows, the run switches to
;;; *partitioned* aggregation: workers only evaluate the keys and arguments
;;; of later morsels and split their rows by key hash into one partition per
;;; worker; each partition is then aggregated by one thread, into a table of
;;; only its share of the groups, together with that partition's groups of
;;; the partial states. Every row carries its input position, so the groups
;;; are still emitted in serial first-appearance order.

(defconstant +partition-group-ratio+ 1/8
  "Groups per input row of a worker's first morsel above which a parallel
aggregation partitions its rows instead of pre-aggregating them.")

(defstruct (partitioned-batch (:constructor make-partitioned-batch (key-vecs arg-vecs rows positions)))
  "One input batch of a partitioned aggregation: its key and argument VECs
and, per partition, the batch rows of that partition (an index vector) and
their input positions."
  key-vecs arg-vecs
  (rows #() :type simple-vector)
  (positions #() :type simple-vector))

(defun partition-batch (key-vecs arg-vecs n base partitions native)
  "PARTITIONED-BATCH of N rows (input positions BASE + i) split into
PARTITIONS by the hash of their keys, as GROUP-STATE-PARTITIONS splits groups."
  (declare (type fixnum n base partitions))
  (let ((hashes (hash-key-vecs key-vecs n native))
        (parts (make-array n :element-type '(unsigned-byte 16)))
        (sizes (make-array partitions :element-type 'fixnum :initial-element 0)))
    (declare (type index-vector hashes))
    (dotimes (i n)
      (let ((p (hash-partition (aref hashes i) partitions)))
        (setf (aref parts i) p)
        (incf (aref sizes p))))
    (let ((rows (map 'simple-vector #'make-index-vector sizes))
          (positions (map 'simple-vector #'make-index-vector sizes)))
      (fill sizes 0)
      (dotimes (i n)
        (let* ((p (aref parts i))
               (k (aref sizes p)))
          (setf (aref (the index-vector (svref rows p)) k) i
                (aref (the index-vector (svref positions p)) k) (+ base i)
                (aref sizes p) (1+ k))))
      (make-partitioned-batch key-vecs arg-vecs rows positions))))

(defun partition-morsel (prepared base partitions native)
  "PARTITIONED-BATCH of the rows of one morsel, given as the list of its
batches' (row-count key-vecs . arg-vecs), in order; BASE is the input
position of its first row."
  (if (null (rest prepared))
      (destructuring-bind (n key-vecs . arg-vecs) (first prepared)
        (partition-batch key-vecs arg-vecs n base partitions native))
      (let ((total (reduce #'+ prepared :key #'first)))
        (flet ((column (k kind-of)
                 (let ((vecs (mapcar (lambda (p) (nth k (funcall kind-of p))) prepared)))
                   (and (first vecs)
                        (vec-concatenate-any vecs total)))))
          (let ((nkeys (length (second (first prepared))))
                (nargs (length (cddr (first prepared)))))
            (partition-batch (loop for k below nkeys collect (column k #'second))
                             (loop for k below nargs collect (column k #'cddr))
                             total base partitions native))))))

(defun consume-partitioned-batch (gs pb p)
  "Aggregate the rows of partition P of the PARTITIONED-BATCH PB into GS."
  (let* ((idx (svref (partitioned-batch-rows pb) p))
         (m (length idx)))
    (when (plusp m)
      (group-state-consume gs
                           (mapcar (lambda (v) (vec-gather v idx m)) (partitioned-batch-key-vecs pb))
                           (mapcar (lambda (v) (and v (vec-gather v idx m)))
                                   (partitioned-batch-arg-vecs pb))
                           m
                           (svref (partitioned-batch-positions pb) p)))))

(defun make-parallel-aggregate (node scan threads)
  "Batch opener of a HashAggregate whose input pipeline runs in up to
THREADS workers, each aggregating into a partial group state (or, with
many groups, partitioning its rows; see above)."
  (let* ((child (pnode-child node))
         (morsel-count (length (scan-morsels scan)))
         (workers (min threads morsel-count))
         (grouped (and (pp-hash-aggregate-group-by node) t))
         (consumers (loop repeat workers
                          collect (multiple-value-list
                                   (let ((*parallel-disabled* t))
                                     (make-aggregate-consumer node :track-positions t))))))
    (multiple-value-bind (copies providers)
        (compile-pipeline-copies child workers (and (third (first consumers)) (pp-table-scan-p child)))
      (lambda ()
        (let ((output nil))
          (lambda ()
            (unless output
              (mapc #'funcall providers)
              (let ((run (make-prun (scan-morsels scan)))
                    (states (make-array workers :initial-element nil))
                    (buffers (make-array workers :initial-element '()))
                    (mode (list nil)))   ; NIL until decided, then :LOCAL or :PARTITION
                (prun-start run workers
                            (lambda (w)
                              (destructuring-bind (new-state consume lazy prepare) (nth w consumers)
                                (declare (ignore lazy))
                                (declare (type function new-state consume prepare))
                                (let ((gs (funcall new-state))
                                      (first-morsel t)
                                      (partition nil))
                                  (setf (svref states w) gs)
                                  (run-morsels
                                   run (svref copies w)
                                   (lambda (m iter)
                                     (declare (type function iter))
                                     ;; Input position: morsel, then row within it.
                                     (let ((base (* m (expt 2 32)))
                                           (rows 0)
                                           (prepared '()))
                                       (declare (type fixnum base rows))
                                       (loop for b = (funcall iter)
                                             while b
                                             do (when (prun-stopped run) (return-from nil))
                                                (let ((n (batch-count b)))
                                                  (if partition
                                                      (multiple-value-bind (key-vecs arg-vecs)
                                                          (funcall prepare b)
                                                        (charge-memory
                                                         (* n (row-footprint (+ (length key-vecs)
                                                                                (length arg-vecs)))))
                                                        (push (list* n key-vecs arg-vecs) prepared))
                                                      (funcall consume gs b base))
                                                  (incf rows n)))
                                       ;; The whole morsel's rows are split at once, so
                                       ;; partitions receive few, large pieces.
                                       (when prepared
                                         (push (partition-morsel (nreverse prepared) base workers
                                                                 (group-state-native gs))
                                               (svref buffers w)))
                                       (when first-morsel
                                         (setf first-morsel nil
                                               partition
                                               (and grouped (> workers 1)
                                                    (eq (decide-aggregation-mode
                                                         mode (> (group-state-count gs)
                                                                 (* rows +partition-group-ratio+)))
                                                        :partition)))))))))))
                ;; Wait for all workers, then merge their partial states in order.
                (loop for th in (prun-threads run)
                      do (sb-thread:join-thread th :default nil))
                (setf (prun-threads run) '())
                (prun-raise run)
                (check-interrupts)
                (setf output (merge-partial-states states node (first (first consumers)) buffers))))
            (funcall (the function output))))))))

(defun decide-aggregation-mode (mode many-groups)
  "The aggregation mode of a run: decided once, by the first worker to finish
a morsel (MODE is a cons cell holding the decision)."
  (let ((wanted (if many-groups :partition :local)))
    (or (sb-ext:compare-and-swap (car mode) nil wanted) wanted)))

(defun merge-partial-states (states node new-state &optional buffers)
  "Batch iterator over the merged groups of the partial group STATES (and of
the partitioned batches in BUFFERS, one list per worker), in order of first
input position (the order a serial aggregation produces). Many groups are
merged in parallel, one thread per hash partition."
  (declare (type simple-vector states) (type function new-state))
  (let ((workers (length states))
        (groups (reduce #'+ states :key #'group-state-count))
        (partitioned (and buffers (some #'identity buffers))))
    (cond
      ((null (pp-hash-aggregate-group-by node))
       (let ((total (svref states 0)))
         (merge-int-distinct-sets states)
         (loop for w from 1 below workers
               do (group-state-merge total (svref states w)))
         (group-state-batches total node)))
      ;; Few groups (below a quarter morsel): a serial merge is cheaper.
      ((and (not partitioned)
            (or (= workers 1) (< groups (floor (morsel-rows) 4))))
       (let ((total (svref states 0)))
         (loop for w from 1 below workers
               do (group-state-merge total (svref states w)))
         (ordered-group-batches (vector total) node)))
      (t
       ;; Partition p collects the groups whose hash is in partition p, from
       ;; every partial state, and the rows of partition p of every
       ;; partitioned batch.
       (let ((parts (coerce (loop repeat workers collect (funcall new-state)) 'simple-vector))
             (split (make-array workers)))
         ;; Each partial state's groups split by partition (in parallel) ...
         (run-in-threads
          (loop for w below workers
                collect (let ((w w))
                          (lambda ()
                            (setf (svref split w)
                                  (group-state-partitions (svref states w) workers))))))
         ;; ... then each partition merges its groups of every partial state
         ;; and aggregates its rows of the partitioned batches.
         (run-in-threads
          (loop for p below workers
                collect (let ((p p))
                          (lambda ()
                            (let ((gs (svref parts p)))
                              (loop for w below workers
                                    do (group-state-merge gs (svref states w)
                                                          (svref (svref split w) p)))
                              (when buffers
                                (loop for w below workers
                                      do (dolist (pb (svref buffers w))
                                           (consume-partitioned-batch gs pb p)
                                           (group-state-charge gs)))))))))
         (check-interrupts)
         (ordered-group-batches parts node workers))))))

(defun merge-int-distinct-sets (states)
  "Without GROUP BY: merge the value sets of the INT-DISTINCT-STATE
aggregates of the partial group STATES into the first state, in parallel:
thread p collects the values of hash partition p from every set. The other
states' sets are emptied, so the regular merge adds nothing."
  (let ((workers (length states)))
    (dotimes (j (length (group-state-aggs (svref states 0))))
      (when (typep (svref (group-state-aggs (svref states 0)) j) 'int-distinct-state)
        (let* ((sets (remove nil (map 'list (lambda (gs)
                                              (svref (int-distinct-state-sets
                                                      (svref (group-state-aggs gs) j))
                                                     0))
                                      states)))
               (total (reduce #'+ sets :key #'key-table-count)))
          (when (and (> workers 1) (>= total (morsel-rows)))
            (let ((parts (make-array workers)))
              (run-in-threads
               (loop for p below workers
                     collect (let ((p p))
                               (lambda ()
                                 (let ((part (make-key-table 1 (ceiling total (* 2 workers)) '(:i64))))
                                   (dolist (set sets)
                                     (let ((keys (svref (key-table-keys set) 0)))
                                       (declare (type simple-vector keys))
                                       (dotimes (k (key-table-count set))
                                         (let ((v (svref keys k)))
                                           (when (= (hash-partition (hash-i64 v) workers) p)
                                             (int-key-probe part v t))))))
                                   (setf (svref parts p) part))))))
              (let ((union (make-key-table 1 (reduce #'+ parts :key #'key-table-count) '(:i64))))
                (loop for part across parts do (int-set-add-all union part))
                (loop for gs across states
                      for w from 0
                      do (setf (svref (int-distinct-state-sets (svref (group-state-aggs gs) j)) 0)
                               (if (zerop w) union nil)))))))))))

(defun ordered-group-batches (states node &optional (threads 1))
  "Iterator over the output batches of the groups of STATES in order of
their first input position. With THREADS > 1 and many groups, the batches
are built in parallel up front."
  (multiple-value-bind (owners gids) (groups-in-position-order states)
    (let* ((nkeys (length (pp-hash-aggregate-group-by node)))
           (kinds (output-kinds node))
           (key-kinds (subseq kinds 0 nkeys))
           (agg-kinds (subseq kinds nkeys))
           (count (length gids))
           (nbatches (ceiling count +batch-size+))
           (pos 0))
      (declare (type fixnum pos))
      (flet ((batch (k)
               (let ((start (* k +batch-size+)))
                 (group-entries-batch owners gids start (min count (+ start +batch-size+))
                                      key-kinds agg-kinds))))
        (if (and (> threads 1) (> nbatches 4))
            (let ((batches (make-array nbatches))
                  (workers (min threads nbatches)))
              (run-in-threads
               (loop for w below workers
                     collect (let ((w w))
                               (lambda ()
                                 (loop for k from w below nbatches by workers
                                       do (setf (svref batches k) (batch k)))))))
              (lambda ()
                (when (< pos nbatches)
                  (prog1 (svref batches pos) (incf pos)))))
            (lambda ()
              (when (< pos nbatches)
                (prog1 (batch pos) (incf pos)))))))))

;;; ------------------------------------------------------------------
;;; Parallel sorting: contiguous chunks of the permutation are sorted
;;; stably in worker threads, then adjacent runs are merged pairwise (in
;;; parallel per round). Ties keep the left run first, so the result equals
;;; a serial stable sort.

(defun run-in-threads (thunks)
  "Call every function of THUNKS in its own thread (the first in the caller)
and wait for all; re-signal the first error."
  (let* ((ctx *query-context*)
         (errors (list nil))
         (threads (mapcar (lambda (thunk)
                            (sb-thread:make-thread
                             (lambda ()
                               (let ((*query-context* ctx)
                                     (*parallel-disabled* t))
                                 (sb-int:with-float-traps-masked
                                     (:overflow :invalid :divide-by-zero :inexact :underflow)
                                   (handler-case (funcall thunk)
                                     (serious-condition (e) (sb-ext:atomic-push e (car errors)))))))
                             :name "polyquery-sort-worker"))
                          (rest thunks))))
    (unwind-protect (funcall (first thunks))
      (mapc (lambda (th) (sb-thread:join-thread th :default nil)) threads))
    (when (car errors) (error (first (car errors))))))

(defun merge-runs (src dst start mid end before)
  "Stably merge the sorted runs SRC[START,MID) and SRC[MID,END) into DST."
  (declare (type index-vector src dst) (type fixnum start mid end) (type function before))
  (let ((i start) (j mid) (k start))
    (declare (type fixnum i j k))
    (loop while (and (< i mid) (< j end))
          do (if (funcall before (aref src j) (aref src i))
                 (progn (setf (aref dst k) (aref src j)) (incf j))
                 (progn (setf (aref dst k) (aref src i)) (incf i)))
             (incf k))
    (replace dst src :start1 k :start2 i :end2 mid)
    (replace dst src :start1 (+ k (- mid i)) :start2 j :end2 end)))

(defun parallel-stable-sort (perm before threads &optional chunk-sort merge)
  "Stably sort the index vector PERM by the predicate BEFORE using up to
THREADS threads; returns the sorted vector. CHUNK-SORT, if given, stably
sorts a chunk (an index vector, returning the sorted one) and MERGE merges
two runs (as MERGE-RUNS without the predicate) in the same order."
  (declare (type index-vector perm))
  (let* ((n (length perm))
         (chunks (min threads (max 1 (floor n (* 2 (morsel-rows))))))
         (chunk-sort (or chunk-sort (lambda (chunk) (stable-sort chunk before))))
         (merge (or merge (lambda (src dst start mid end)
                            (merge-runs src dst start mid end before)))))
    (declare (type function chunk-sort merge))
    (if (<= chunks 1)
        (funcall chunk-sort perm)
        (let ((bounds (loop for k to chunks collect (floor (* k n) chunks))))
          (run-in-threads
           (loop for (a b) on bounds
                 while b
                 collect (let ((a a) (b b))
                           (lambda ()
                             (replace perm (funcall chunk-sort (subseq perm a b)) :start1 a)))))
          (let ((src perm)
                (dst (make-index-vector n))
                (runs (loop for (a b) on bounds while b collect (cons a b))))
            (loop while (rest runs)
                  do (let ((pairs (loop for (r1 r2) on runs by #'cddr collect (cons r1 r2))))
                       (let ((s src) (d dst))
                         (run-in-threads
                          (mapcar (lambda (pair)
                                    (destructuring-bind ((a . m) . r2) pair
                                      (if r2
                                          (lambda () (funcall merge s d a m (cdr r2)))
                                          (lambda () (replace d s :start1 a :start2 a :end2 m)))))
                                  pairs)))
                       (setf runs (mapcar (lambda (pair)
                                            (cons (car (car pair))
                                                  (if (cdr pair) (cdr (cdr pair)) (cdr (car pair)))))
                                          pairs))
                       (rotatef src dst)))
            src)))))

;;; ------------------------------------------------------------------
;;; Hooking into the batch compiler

(defun compile-parallel (node)
  "A parallel batch opener for NODE, or NIL when NODE runs serially."
  (let ((threads (parallel-threads)))
    (when (> threads 1)
      (typecase node
        (pp-hash-aggregate
         (let ((scan (and (parallel-safe-node-p node) (pipeline-scan (pnode-child node)))))
           (when (and scan (> (length (scan-morsels scan)) 1))
             (make-parallel-aggregate node scan threads))))
        (pp-hash-distinct
         ;; DISTINCT is a grouping on all columns without aggregates.
         (let* ((child (pnode-child node))
                (scan (pipeline-scan child)))
           (when (and scan (> (length (scan-morsels scan)) 1))
             (make-parallel-aggregate
              (make-pp-hash-aggregate :children (list child) :columns (pnode-columns node)
                                      :group-by (loop for c in (pnode-columns child)
                                                      for i from 0
                                                      collect (make-b-column (column-def-type c) i
                                                                             (column-def-name c)))
                                      :aggregates '())
              scan threads))))
        ((or pp-filter pp-project pp-hash-join pp-table-scan)
         (let ((scan (pipeline-scan node)))
           (when (and scan (> (length (scan-morsels scan)) 1))
             (make-parallel-gather node scan threads))))))))

(defmethod compile-batch-operator :around ((node pnode))
  (or (compile-parallel node) (call-next-method)))
