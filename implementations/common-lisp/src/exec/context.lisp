;;;; context.lisp — per-query execution context: deadline, cancellation and
;;;; approximate memory accounting.

(in-package #:polyquery)

(defstruct query-context
  (deadline nil)                    ; internal real time, or NIL
  (cancelled nil)                   ; set asynchronously to request cancellation
  (memory-budget (* 2048 1024 1024))
  (max-join-rows nil)               ; limit on rows produced by one join, or NIL
  (memory-used 0 :type sb-ext:word) ; updated atomically (parallel workers)
  (cleanups '()))                   ; functions to run when the query ends

(defvar *query-context* nil
  "The context of the query currently executing in this thread.")

(defun timed-condition-wait (queue mutex timeout)
  "CONDITION-WAIT on QUEUE for at most TIMEOUT seconds, returning with MUTEX
held in every case (SBCL's CONDITION-WAIT returns from a timeout without
re-acquiring the mutex). Returns true if woken up."
  (or (sb-thread:condition-wait queue mutex :timeout timeout)
      (progn (unless (sb-thread:holding-mutex-p mutex)
               (sb-thread:grab-mutex mutex))
             nil)))

(defun make-deadline (timeout-ms)
  (when (and timeout-ms (plusp timeout-ms))
    (+ (get-internal-real-time)
       (ceiling (* timeout-ms internal-time-units-per-second) 1000))))

(defun check-interrupts ()
  "Signal TIMEOUT or CANCELLED when the current query must stop."
  (let ((ctx *query-context*))
    (when ctx
      (when (query-context-cancelled ctx)
        (signal-pq-error "CANCELLED" "query was cancelled"))
      (let ((deadline (query-context-deadline ctx)))
        (when (and deadline (> (get-internal-real-time) deadline))
          (signal-pq-error "TIMEOUT" "query exceeded its timeout"))))))

(defun charge-memory (bytes)
  "Account BYTES of materialized state against the query memory budget."
  (let ((ctx *query-context*))
    (when ctx
      (when (> (+ (sb-ext:atomic-incf (query-context-memory-used ctx) bytes) bytes)
               (query-context-memory-budget ctx))
        (resource-limit-error "query exceeded its memory budget of ~D MB"
                              (floor (query-context-memory-budget ctx) (* 1024 1024)))))))

(defun add-query-cleanup (fn)
  "Arrange for FN to be called when the current query ends (normally or not)."
  (let ((ctx *query-context*))
    (when ctx
      (sb-ext:atomic-push fn (query-context-cleanups ctx)))))

(defun run-query-cleanups (ctx)
  "Run (and forget) the cleanups registered for CTX, most recent first."
  (when ctx
    (loop for fn = (sb-ext:atomic-pop (query-context-cleanups ctx))
          while fn
          do (funcall (the function fn)))))

(defmacro with-query-cleanups ((ctx) &body body)
  "Run BODY, then the cleanups registered for the query context CTX."
  (let ((c (gensym "CTX")))
    `(let ((,c ,ctx))
       (unwind-protect (progn ,@body)
         (run-query-cleanups ,c)))))

(defun row-footprint (width)
  "Approximate bytes held by one materialized row of WIDTH values."
  (* 8 (+ 2 width)))

;;; ------------------------------------------------------------------
;;; Execution options (protocol.md §5.2, phase-5.md)

(defstruct exec-options
  (mode :auto)                      ; :AUTO, :ROW or :VECTORIZED
  (threads 1)                       ; worker threads for scans and aggregation
  (join :auto)                      ; :AUTO, :HASH, :MERGE or :NESTED-LOOP
  (optimize t)                      ; NIL disables the logical rewrites
  (use-indexes t)                   ; NIL never plans index scans
  (native nil))                     ; native kernels requested (none are loaded)

(defvar *exec-options* (make-exec-options)
  "Options of the statement being planned or compiled.")

(defvar *parallel-disabled* nil
  "True while compiling or running code that must not start parallel workers
(inside a worker, or a subquery).")

(defun vectorized-execution-p (&optional (options *exec-options*))
  "True when the statement runs on the batch (vectorized) executor."
  (not (eq (exec-options-mode options) :row)))
