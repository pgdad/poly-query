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
;;;; Pipelines whose expressions contain subqueries or correlation
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
  "True if NODE's expressions can be evaluated by independent workers."
  (notany (lambda (e)
            (and e (bexpr-some (lambda (x) (or (b-param-p x) (subquery-op-p x))) e)))
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

(defun scan-morsel-rows (scan)
  "Rows per morsel of SCAN: MORSEL-ROWS, but smaller for small tables (down to
a batch) so that every worker gets about four morsels; a forced size
(*MORSEL-ROWS* or POLYQUERY_MORSEL_ROWS) is used as is."
  (let ((size (morsel-rows)))
    (if (or *morsel-rows* (/= size 16384))
        size
        (let ((rows (reduce #'+ (scan-segments scan) :key #'segment-count))
              (threads (max 1 (parallel-threads))))
          (max +batch-size+ (min size (* +batch-size+ (ceiling rows (* 4 threads +batch-size+)))))))))

(defun scan-morsels (scan)
  "Vector of the (segment start end) morsels of a TableScan."
  (let ((size (scan-morsel-rows scan)))
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

(defun make-parallel-gather (node scan threads &key reduce)
  "Batch opener running the pipeline NODE (over SCAN) in up to THREADS
workers, yielding the batches in serial order. REDUCE, when given, maps the
list of output batches of each morsel to the batches handed on (in the
worker)."
  (let* ((morsels (scan-morsels scan))   ; fixed at compile time
         (morsel-count (length morsels))
         (workers (min threads morsel-count)))
    (multiple-value-bind (copies providers) (compile-pipeline-copies node workers)
      (lambda ()
        (mapc #'funcall providers)
        (let* ((run (make-prun morsels))
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
                                         (setf batches (nreverse batches))
                                         (when reduce
                                           (setf batches (funcall (the function reduce) batches)))
                                         (sb-thread:with-mutex ((prun-mutex run))
                                           (setf (svref (prun-results run) m) batches)
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
;;; Every worker aggregates the morsels it claims into its own partial
;;; group state. With many groups, merging the partial states (each holding
;;; most of the groups) costs about as much as the aggregation itself, so a
;;; worker whose partial state exceeds *PARTITION-GROUPS-THRESHOLD* groups
;;; switches to *partitioning*: it only evaluates the key and argument
;;; vectors of its later batches and files their rows by key hash into one
;;; chunk list per partition (one partition per worker). Afterwards every
;;; partition is aggregated by its own thread: the chunks filed for it by all
;;; workers, plus its share (by the same hash) of the workers' partial
;;; states. Each row is then hashed into a table once, and every partition's
;;; table holds only its share of the groups.

(defparameter *partition-groups-threshold* 4096
  "Partial-state size above which a worker of a parallel aggregation
switches to partitioning its input rows.")

(defstruct (row-chunk (:constructor make-row-chunk (key-vecs arg-vecs count positions)))
  "Rows of one batch filed for a partition: their key and aggregate argument
vectors and input positions."
  key-vecs arg-vecs (count 0 :type fixnum) (positions nil :type index-vector))

(defun partition-rows (key-vecs arg-vecs n base chunk-lists)
  "File the N rows of KEY-VECS/ARG-VECS (input positions BASE + i) into the
CHUNK-LISTS (one list per partition) by key hash, the partition of a group
as in GROUP-STATE-PARTITIONS."
  (declare (type fixnum n base) (type simple-vector chunk-lists))
  (let* ((parts (length chunk-lists))
         (hashes (hash-key-vecs key-vecs n))
         (sizes (make-array parts :element-type 'fixnum :initial-element 0)))
    (declare (type index-vector hashes))
    (dotimes (i n)
      (let ((p (mod (aref hashes i) parts)))
        (setf (aref hashes i) p)
        (incf (aref sizes p))))
    (let ((indexes (map 'simple-vector #'make-index-vector sizes)))
      (fill sizes 0)
      (dotimes (i n)
        (let ((p (aref hashes i)))
          (setf (aref (the index-vector (svref indexes p)) (aref sizes p)) i)
          (incf (aref sizes p))))
      (dotimes (p parts)
        (let ((m (aref sizes p))
              (idx (svref indexes p)))
          (declare (type index-vector idx))
          (when (plusp m)
            (let ((positions (make-index-vector m)))
              (dotimes (j m) (setf (aref positions j) (+ base (aref idx j))))
              (push (make-row-chunk (mapcar (lambda (v) (vec-gather v idx m)) key-vecs)
                                    (mapcar (lambda (v) (and v (vec-gather v idx m))) arg-vecs)
                                    m positions)
                    (svref chunk-lists p)))))))))

(defun make-parallel-aggregate (node scan threads)
  "Batch opener of a HashAggregate whose input pipeline runs in up to
THREADS workers, each aggregating into a partial group state (or
partitioning its rows, see above)."
  (let* ((child (pnode-child node))
         (morsels (scan-morsels scan))   ; fixed at compile time
         (morsel-count (length morsels))
         (workers (min threads morsel-count))
         (consumers (loop repeat workers
                          collect (multiple-value-list
                                   (let ((*parallel-disabled* t))
                                     (make-aggregate-consumer node :track-positions t)))))
         (lazy (third (first consumers)))
         (partitionable (and (pp-hash-aggregate-group-by node) (not lazy))))
    (multiple-value-bind (copies providers)
        (compile-pipeline-copies child workers (and lazy (pp-table-scan-p child)))
      (lambda ()
        (let ((output nil))
          (lambda ()
            (unless output
              (mapc #'funcall providers)
              (let ((run (make-prun morsels))
                    (states (make-array workers :initial-element nil))
                    (chunk-lists (make-array workers :initial-element nil)))
                (prun-start run workers
                            (lambda (w)
                              (destructuring-bind (new-state consume lazy evaluate consume-vecs)
                                  (nth w consumers)
                                (declare (ignore lazy consume-vecs))
                                (declare (type function new-state consume evaluate))
                                (let ((gs (funcall new-state))
                                      (width (length (pnode-columns child)))
                                      (partitioning nil))
                                  (setf (svref states w) gs)
                                  (run-morsels run (svref copies w)
                                               (lambda (m iter)
                                                 (declare (type function iter))
                                                 ;; Input position: morsel, then row within it.
                                                 (let ((base (* m (expt 2 32))))
                                                   (loop for b = (funcall iter)
                                                         while b
                                                         do (when (prun-stopped run) (return-from nil))
                                                            (if partitioning
                                                                (multiple-value-bind (key-vecs arg-vecs)
                                                                    (funcall evaluate b)
                                                                  (charge-memory (* (batch-count b)
                                                                                    (row-footprint width)))
                                                                  (partition-rows key-vecs arg-vecs
                                                                                  (batch-count b) base
                                                                                  partitioning))
                                                                (progn
                                                                  (funcall consume gs b base)
                                                                  (when (and partitionable
                                                                             (> (group-state-count gs)
                                                                                *partition-groups-threshold*))
                                                                    (setf partitioning
                                                                          (make-array workers :initial-element '())
                                                                          (svref chunk-lists w) partitioning))))
                                                            (incf base (batch-count b))))))))))
                ;; Wait for all workers, then merge their partial states in order.
                (loop for th in (prun-threads run)
                      do (sb-thread:join-thread th :default nil))
                (setf (prun-threads run) '())
                (prun-raise run)
                (check-interrupts)
                (setf output
                      (if (some #'identity chunk-lists)
                          (merge-partitioned-states states chunk-lists node
                                                    (first (first consumers))
                                                    (fifth (first consumers)))
                          (merge-partial-states states node (first (first consumers)))))))
            (funcall (the function output))))))))

(defun merge-partitioned-states (states chunk-lists node new-state consume-vecs)
  "Batch iterator over the groups of a parallel aggregation in which some
workers partitioned their rows into CHUNK-LISTS (per worker: NIL, or a
vector of chunk lists by partition): each partition aggregates, in its own
thread, its chunks and its groups of the partial STATES."
  (declare (type simple-vector states chunk-lists) (type function new-state consume-vecs))
  (let* ((workers (length states))
         (parts (coerce (loop repeat workers collect (funcall new-state)) 'simple-vector))
         (partitioned (make-array workers)))
    (run-in-threads
     (loop for w below workers
           collect (let ((w w))
                     (lambda ()
                       (setf (svref partitioned w)
                             (group-state-partitions (svref states w) workers))))))
    (run-in-threads
     (loop for p below workers
           collect (let ((p p))
                     (lambda ()
                       (let ((gs (svref parts p)))
                         (loop for lists across chunk-lists
                               when lists
                                 do (dolist (chunk (reverse (svref lists p)))
                                      (funcall consume-vecs gs (row-chunk-key-vecs chunk)
                                               (row-chunk-arg-vecs chunk) (row-chunk-count chunk)
                                               (row-chunk-positions chunk))))
                         (loop for w below workers
                               do (group-state-merge gs (svref states w)
                                                     (svref (svref partitioned w) p))))))))
    (check-interrupts)
    (ordered-group-batches parts node)))

(defun merge-partial-states (states node new-state)
  "Batch iterator over the merged groups of the partial group STATES, in
order of first input position (the order a serial aggregation produces).
Many groups are merged in parallel, one thread per hash partition."
  (declare (type simple-vector states) (type function new-state))
  (let ((workers (length states))
        (groups (reduce #'+ states :key #'group-state-count)))
    (cond
      ((null (pp-hash-aggregate-group-by node))
       (let ((total (svref states 0)))
         (when (> workers 1)
           (merge-distinct-states-in-parallel total states))
         (loop for w from 1 below workers
               do (group-state-merge total (svref states w)))
         (group-state-batches total node)))
      ;; Few groups (below a quarter morsel): a serial merge is cheaper.
      ((or (= workers 1) (< groups (floor (morsel-rows) 4)))
       (let ((total (svref states 0)))
         (loop for w from 1 below workers
               do (group-state-merge total (svref states w)))
         (ordered-group-batches (vector total) node)))
      (t
       ;; Partition p collects the groups whose hash is p modulo the number
       ;; of partitions, from every partial state.
       (let ((parts (coerce (loop repeat workers collect (funcall new-state)) 'simple-vector))
             (partitioned (make-array workers)))
         ;; Each partial state's groups split by partition (in parallel) ...
         (run-in-threads
          (loop for w below workers
                collect (let ((w w))
                          (lambda ()
                            (setf (svref partitioned w)
                                  (group-state-partitions (svref states w) workers))))))
         ;; ... then each partition merges its groups of every partial state.
         (run-in-threads
          (loop for p below workers
                collect (let ((p p))
                          (lambda ()
                            (loop for w below workers
                                  do (group-state-merge (svref parts p) (svref states w)
                                                        (svref (svref partitioned w) p)))))))
         (check-interrupts)
         (ordered-group-batches parts node))))))

(defun ordered-group-batches (states node)
  "Iterator over the output batches of the groups of STATES in order of
their first input position (many groups: built in parallel up front)."
  (multiple-value-bind (owners gids) (groups-in-position-order states (length states))
    (let* ((nkeys (length (pp-hash-aggregate-group-by node)))
           (kinds (output-kinds node))
           (key-kinds (subseq kinds 0 nkeys))
           (agg-kinds (subseq kinds nkeys))
           (count (length gids))
           (pos 0))
      (declare (type fixnum pos))
      (if (and (> (length states) 1) (> count (* 4 +batch-size+)))
          (let* ((nbatches (ceiling count +batch-size+))
                 (batches (make-array nbatches))
                 (k 0))
            (declare (type fixnum k))
            (map-row-ranges nbatches (length states)
                            (lambda (start end)
                              (loop for b from start below end
                                    do (setf (svref batches b)
                                             (group-entries-batch owners gids (* b +batch-size+)
                                                                  (min count (* (1+ b) +batch-size+))
                                                                  key-kinds agg-kinds))))
                            2)
            (lambda ()
              (when (< k nbatches)
                (prog1 (svref batches k)
                  (setf (svref batches k) nil)
                  (incf k)))))
          (lambda ()
            (when (< pos count)
              (let ((end (min count (+ pos +batch-size+))))
                (prog1 (group-entries-batch owners gids pos end key-kinds agg-kinds)
                  (setf pos end)))))))))

;;; ------------------------------------------------------------------
;;; Parallel sorting: contiguous chunks of the permutation are sorted
;;; stably in worker threads, then adjacent runs are merged pairwise (in
;;; parallel per round). Ties keep the left run first, so the result equals
;;; a serial stable sort.

(defun run-in-threads (thunks)
  "Call every function of THUNKS in its own thread (the first in the caller)
and wait for all; re-signal the first error."
  (when (null thunks)
    (return-from run-in-threads nil))
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

(defun parallel-stable-sort (perm before threads)
  "Stably sort the index vector PERM by the predicate BEFORE using up to
THREADS threads; returns the sorted vector."
  (declare (type index-vector perm))
  (let* ((n (length perm))
         (chunks (min threads (max 1 (floor n (* 2 (morsel-rows)))))))
    (if (<= chunks 1)
        (stable-sort perm before)
        (let ((bounds (loop for k to chunks collect (floor (* k n) chunks))))
          (run-in-threads
           (loop for (a b) on bounds
                 while b
                 collect (let ((a a) (b b))
                           (lambda ()
                             (replace perm (stable-sort (subseq perm a b) before) :start1 a)))))
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
                                          (lambda () (merge-runs s d a m (cdr r2) before))
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

;;; ------------------------------------------------------------------
;;; Shared CTE results: plans inside references to one CTE with equal share
;;; keys (see CTE-SHARE-KEY) that occur more than once in a statement
;;; (counting the plans of its subqueries) are compiled once and their rows
;;; materialized on first use; every occurrence then reads the stored rows.
;;; Pipelines over a table scan are not shared (cheap to recompute, and
;;; parallel when read).

(defvar *shared-results* nil
  "Per statement being compiled: hash table from share keys to their number
of occurrences in the statement's plans, or to their SHARED-RESULT.")

(defun make-shared-results-table (root)
  "Table of the share keys occurring more than once in the plan ROOT and the
plans of its subqueries (values: occurrence counts), or NIL if there are none."
  (let ((counts (make-hash-table :test 'equal))
        (any nil))
    (labels ((walk (node)
               (let ((key (pnode-share-key node)))
                 (when key
                   (when (> (incf (gethash key counts 0)) 1) (setf any t))))
               (dolist (e (node-expressions node))
                 (when e
                   (bexpr-some (lambda (x)
                                 (when (subquery-op-p x)
                                   (walk (subquery-plan (b-op-info x))))
                                 nil)
                               e)))
               (mapc #'walk (pnode-children node))))
      (walk root))
    (and any counts)))

(defstruct (shared-result (:constructor make-shared-result (opener)))
  opener                                 ; batch opener of the shared plan
  (batch nil)                            ; its rows, once materialized
  (mutex (sb-thread:make-mutex :name "shared result")))

(defun make-shared-reader (node key compile)
  "Batch opener reading the shared rows of the plan NODE with share KEY;
COMPILE compiles NODE's own opener (once per statement)."
  (declare (type function compile))
  (let ((entry (let ((value (gethash key *shared-results*)))
                 (if (shared-result-p value)
                     value
                     (setf (gethash key *shared-results*)
                           ;; Plans below a shared one are compiled once with it.
                           (make-shared-result (let ((*shared-results* nil)) (funcall compile)))))))
        (kinds (output-kinds node)))
    (lambda ()
      (let* ((batch (sb-thread:with-recursive-lock ((shared-result-mutex entry))
                      (or (shared-result-batch entry)
                          (setf (shared-result-batch entry)
                                (drain-batches (shared-result-opener entry) kinds)))))
             (n (batch-count batch))
             (pos 0))
        (declare (type fixnum n pos))
        (lambda ()
          (when (< pos n)
            (let ((end (min n (+ pos +batch-size+))))
              (prog1 (batch-slice batch pos end)
                (setf pos end)))))))))

(defmethod compile-batch-operator :around ((node pnode))
  (let ((key (pnode-share-key node)))
    (if (and key *shared-results*
             (let ((value (gethash key *shared-results*)))
               (or (shared-result-p value) (and value (> value 1))))
             (not (pipeline-scan node)))
        (make-shared-reader node key
                            (lambda () (or (compile-parallel node) (call-next-method))))
        (or (compile-parallel node) (call-next-method)))))
