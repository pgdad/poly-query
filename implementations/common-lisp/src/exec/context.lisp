;;;; context.lisp — per-query execution context: deadline, cancellation and
;;;; approximate memory accounting.

(in-package #:polyquery)

(defstruct query-context
  (deadline nil)                    ; internal real time, or NIL
  (cancelled nil)                   ; set asynchronously to request cancellation
  (memory-budget (* 2048 1024 1024))
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
