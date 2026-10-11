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
  (if *parallel-disabled* 1 (exec-options-threads *exec-options*)))

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

(defun compile-pipeline-copy (node builds cells)
  "Compile a private copy of the pipeline NODE. BUILDS and CELLS map the
pipeline's hash joins to their shared build providers and row counters."
  (let* ((cell (list nil))
         (opener
           (let ((*parallel-disabled* t))
             (labels ((compile-node (n)
                        (etypecase n
                          (pp-table-scan
                           (make-batch-scan n :ranges (lambda () (shiftf (car cell) nil))))
                          (pp-filter (make-batch-filter (compile-node (pnode-child n))
                                                        (pp-filter-predicate n)))
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

(defun compile-pipeline-copies (node count)
  "(values copies providers): COUNT private copies of the pipeline NODE and
the shared build providers of its hash joins (to be forced before the
workers start)."
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
    (values (coerce (loop repeat count collect (compile-pipeline-copy node shared cells))
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
  (error nil)
  (stopped nil)
  (mutex (sb-thread:make-mutex :name "parallel run"))
  (cv (sb-thread:make-waitqueue :name "parallel run"))
  (threads '()))

(defun prun-fail (run condition)
  (sb-thread:with-mutex ((prun-mutex run))
    (unless (prun-error run) (setf (prun-error run) condition))
    (setf (prun-stopped run) t)
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
              ((or (null window) (< next (+ (prun-consumed run) window)))
               (setf (prun-next run) (1+ next))
               (return next))
              (t (sb-thread:condition-wait (prun-cv run) (prun-mutex run) :timeout 0.1)))))))

(defun prun-start (run count body)
  "Start COUNT workers calling (BODY worker-index) with the query's dynamic
environment; register their shutdown as a query cleanup."
  (let ((ctx *query-context*)
        (options *exec-options*))
    (add-query-cleanup (lambda () (prun-stop run)))
    (setf (prun-threads run)
          (loop for w below count
                collect (let ((w w))
                          (sb-thread:make-thread
                           (lambda ()
                             (let ((*query-context* ctx)
                                   (*exec-options* options)
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

(defun run-morsel (copy morsel run)
  "Open the pipeline COPY on MORSEL; returns its iterator."
  (declare (ignore run))
  (setf (car (pipeline-copy-cell copy)) morsel)
  (funcall (the function (pipeline-copy-opener copy))))

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
                        (let ((copy (svref copies w)))
                          (loop for m = (prun-claim run)
                                while m
                                do (let ((iter (run-morsel copy (svref (prun-morsels run) m) run))
                                         (batches '()))
                                     (declare (type function iter))
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
                  (loop until (or (prun-error run)
                                  (not (eq (svref (prun-results run) k) :pending)))
                        do (sb-thread:condition-wait (prun-cv run) (prun-mutex run) :timeout 0.05)
                           (return))
                  (unless (or (prun-error run) (eq (svref (prun-results run) k) :pending))
                    (setf pending (svref (prun-results run) k)
                          (svref (prun-results run) k) nil
                          ready t)
                    (incf k)
                    (setf (prun-consumed run) k)
                    (sb-thread:condition-broadcast (prun-cv run))))
                (prun-raise run)
                (unless ready (check-interrupts))))))))))

;;; ------------------------------------------------------------------
;;; Parallel aggregation

(defun make-parallel-aggregate (node scan threads)
  "Batch opener of a HashAggregate whose input pipeline runs in up to
THREADS workers, each aggregating into a partial group state."
  (let* ((child (pnode-child node))
         (morsel-count (length (scan-morsels scan)))
         (workers (min threads morsel-count))
         (consumers (loop repeat workers
                          collect (multiple-value-list
                                   (let ((*parallel-disabled* t))
                                     (make-aggregate-consumer node))))))
    (multiple-value-bind (copies providers) (compile-pipeline-copies child workers)
      (lambda ()
        (let ((output nil))
          (lambda ()
            (unless output
              (mapc #'funcall providers)
              (let ((run (make-prun (scan-morsels scan)))
                    (states (make-array workers :initial-element nil)))
                (prun-start run workers
                            (lambda (w)
                              (destructuring-bind (new-state consume) (nth w consumers)
                                (declare (type function new-state consume))
                                (let ((gs (funcall new-state))
                                      (copy (svref copies w)))
                                  (setf (svref states w) gs)
                                  (loop for m = (prun-claim run)
                                        while m
                                        do (let ((iter (run-morsel copy (svref (prun-morsels run) m) run)))
                                             (declare (type function iter))
                                             (loop for b = (funcall iter)
                                                   while b
                                                   do (when (prun-stopped run) (return-from nil))
                                                      (funcall consume gs b))))))))
                ;; Wait for all workers, then merge their partial states in order.
                (loop for th in (prun-threads run)
                      do (sb-thread:join-thread th :default nil))
                (setf (prun-threads run) '())
                (prun-raise run)
                (check-interrupts)
                (let ((total (svref states 0)))
                  (loop for w from 1 below workers
                        do (group-state-merge total (svref states w)))
                  (setf output (group-state-batches total node)))))
            (funcall (the function output))))))))

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
