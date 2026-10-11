;;;; context.lisp — per-query execution context: deadline, cancellation and
;;;; approximate memory accounting.

(in-package #:polyquery)

(defstruct query-context
  (deadline nil)                    ; internal real time, or NIL
  (cancelled nil)                   ; set asynchronously to request cancellation
  (memory-budget (* 2048 1024 1024))
  (max-join-rows nil)               ; limit on rows produced by one join, or NIL
  (memory-used 0))

(defvar *query-context* nil
  "The context of the query currently executing in this thread.")

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
      (when (> (incf (query-context-memory-used ctx) bytes)
               (query-context-memory-budget ctx))
        (resource-limit-error "query exceeded its memory budget of ~D MB"
                              (floor (query-context-memory-budget ctx) (* 1024 1024)))))))

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

(defun vectorized-execution-p (&optional (options *exec-options*))
  "True when the statement runs on the batch (vectorized) executor."
  (not (eq (exec-options-mode options) :row)))
