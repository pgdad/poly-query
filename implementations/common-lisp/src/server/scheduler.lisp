;;;; scheduler.lisp — admission control for `serve` (concurrency.md §2–§4).
;;;;
;;;; A fixed pool of worker threads executes query JOBs taken from a bounded
;;;; FIFO queue: at most WORKERS jobs run and at most QUEUE-DEPTH wait; any
;;;; further submission is rejected with OVERLOADED. Every active job is
;;;; registered under its query id for listing and cancellation.
;;;;
;;;; A job completes exactly once (FINISH-JOB is first-writer-wins), either by
;;;; its worker or by the thread waiting for it when it is cancelled or times
;;;; out while still queued (or overruns its stop deadline while running).
;;;; Everything is guarded by the single scheduler mutex.

(in-package #:polyquery)

(defconstant +stop-grace-seconds+ 0.05
  "How long a running job may take to notice cancellation/timeout before its
waiter completes it on the worker's behalf.")

(defstruct (job (:constructor %make-job))
  (query-id "" :type string)
  (request-id :null)                     ; protocol id echoed in error responses
  (thunk nil :type (or null function))   ; run by a worker; returns the response
  (context nil)                          ; QUERY-CONTEXT (deadline, cancel flag)
  (state :queued)                        ; :QUEUED, :RUNNING or :DONE
  (result nil)                           ; the response object once :DONE
  (done (sb-thread:make-waitqueue))
  (submitted (get-internal-real-time))
  (stop-requested nil)                   ; internal time a cancel was requested
  (on-complete nil))                     ; (lambda (job)) called once after completion

(defstruct (scheduler (:constructor %make-scheduler))
  (workers 1 :type (integer 1))
  (queue-depth 0 :type (integer 0))
  (lock (sb-thread:make-mutex :name "scheduler"))
  (work-available (sb-thread:make-waitqueue))
  (queue '() :type list)                 ; FIFO of queued jobs
  (queued 0 :type fixnum)
  (running 0 :type fixnum)
  (registry (make-hash-table :test 'equal))
  (next-id 0 :type fixnum)
  (accepting t)
  (threads '()))

(defun make-scheduler (&key (workers 1) (queue-depth 64))
  "Create a scheduler and start its WORKERS worker threads."
  (let ((scheduler (%make-scheduler :workers (max 1 workers) :queue-depth queue-depth)))
    (setf (scheduler-threads scheduler)
          (loop for k from 1 to (scheduler-workers scheduler)
                collect (sb-thread:make-thread #'worker-loop :name (format nil "worker-~D" k)
                                                            :arguments (list scheduler))))
    scheduler))

(defun make-job (&key query-id request-id thunk context on-complete)
  (%make-job :query-id (or query-id "") :request-id request-id :thunk thunk
             :context context :on-complete on-complete))

(defun seconds-since (internal-time)
  (/ (- (get-internal-real-time) internal-time) internal-time-units-per-second))

(defun job-elapsed-ms (job)
  (floor (* 1000 (seconds-since (job-submitted job)))))

;;; ------------------------------------------------------------------
;;; Submission

(defun %fresh-query-id (scheduler)
  (loop for id = (format nil "q~D" (incf (scheduler-next-id scheduler)))
        unless (gethash id (scheduler-registry scheduler)) return id))

(defun submit-job (scheduler job)
  "Queue JOB for execution, assigning a query id if it has none. Signals a
PQ-ERROR (SHUTTING_DOWN, ALREADY_EXISTS or OVERLOADED) if it is not admitted."
  (sb-thread:with-mutex ((scheduler-lock scheduler))
    (unless (scheduler-accepting scheduler)
      (signal-pq-error "SHUTTING_DOWN" "the server is shutting down"))
    (if (zerop (length (job-query-id job)))
        (setf (job-query-id job) (%fresh-query-id scheduler))
        (when (gethash (job-query-id job) (scheduler-registry scheduler))
          (signal-pq-error "ALREADY_EXISTS" "query id ~S is already in use" (job-query-id job))))
    (when (>= (+ (scheduler-running scheduler) (scheduler-queued scheduler))
              (+ (scheduler-workers scheduler) (scheduler-queue-depth scheduler)))
      (signal-pq-error "OVERLOADED" "all ~D workers are busy and the queue is full"
                       (scheduler-workers scheduler)))
    (setf (scheduler-queue scheduler) (nconc (scheduler-queue scheduler) (list job))
          (gethash (job-query-id job) (scheduler-registry scheduler)) job)
    (incf (scheduler-queued scheduler))
    (sb-thread:condition-notify (scheduler-work-available scheduler))
    job))

;;; ------------------------------------------------------------------
;;; Completion

(defun %finish-job (scheduler job result)
  "Complete JOB with RESULT unless already done. Caller holds the lock.
Returns true if this call completed it."
  (unless (eq (job-state job) :done)
    (when (eq (job-state job) :queued)
      (setf (scheduler-queue scheduler) (delete job (scheduler-queue scheduler)))
      (decf (scheduler-queued scheduler)))
    (setf (job-state job) :done
          (job-result job) result)
    (when (eq (gethash (job-query-id job) (scheduler-registry scheduler)) job)
      (remhash (job-query-id job) (scheduler-registry scheduler)))
    (sb-thread:condition-broadcast (job-done job))
    t))

(defun finish-job (scheduler job result)
  (when (sb-thread:with-mutex ((scheduler-lock scheduler))
          (%finish-job scheduler job result))
    (run-completion-hook job)))

(defun run-completion-hook (job)
  (let ((hook (job-on-complete job)))
    (when hook
      (handler-case (funcall hook job)
        (error (e) (log-message :error "completion hook failed: ~A" e))))))

;;; ------------------------------------------------------------------
;;; Workers

(defun run-job (job)
  "Run JOB's thunk, turning anything that escapes it into an error response."
  (handler-case (funcall (job-thunk job))
    (serious-condition (e)
      (log-message :error "query ~A failed: ~A" (job-query-id job) e)
      (error-response (job-request-id job) "INTERNAL_ERROR" "internal error while executing the query"))))

(defun worker-loop (scheduler)
  (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
    (let ((lock (scheduler-lock scheduler)))
      (loop
        (let ((job (sb-thread:with-mutex (lock)
                     (loop until (scheduler-queue scheduler)
                           do (sb-thread:condition-wait (scheduler-work-available scheduler) lock))
                     (let ((job (pop (scheduler-queue scheduler))))
                       (decf (scheduler-queued scheduler))
                       (incf (scheduler-running scheduler))
                       (setf (job-state job) :running)
                       job))))
          (let ((result (run-job job)))
            (sb-thread:with-mutex (lock)
              (decf (scheduler-running scheduler)))
            (finish-job scheduler job result)))))))

;;; ------------------------------------------------------------------
;;; Waiting, timeouts and cancellation

(defun job-overdue-code (job)
  "The error code with which the waiter must complete JOB itself now, or NIL.
Queued jobs stop as soon as they are cancelled or their deadline passes;
running jobs are given +STOP-GRACE-SECONDS+ to stop on their own."
  (let* ((ctx (job-context job))
         (deadline (and ctx (query-context-deadline ctx)))
         (now (get-internal-real-time))
         (grace (if (eq (job-state job) :queued)
                    0
                    (ceiling (* +stop-grace-seconds+ internal-time-units-per-second)))))
    (cond ((and (job-stop-requested job) (> now (+ (job-stop-requested job) grace)))
           "CANCELLED")
          ((and deadline (> now (+ deadline grace)))
           "TIMEOUT")
          ((and (eq (job-state job) :queued) ctx (query-context-cancelled ctx))
           "CANCELLED"))))

(defun overdue-response (job code)
  (error-response (job-request-id job) code
                  (if (string= code "TIMEOUT") "query exceeded its timeout" "query was cancelled")))

(defun poll-job (scheduler job)
  "Complete JOB on its worker's behalf if it is overdue (see JOB-OVERDUE-CODE)."
  (let ((completed
          (sb-thread:with-mutex ((scheduler-lock scheduler))
            (let ((code (and (not (eq (job-state job) :done)) (job-overdue-code job))))
              (when code
                (when (job-context job)
                  (setf (query-context-cancelled (job-context job)) t))
                (%finish-job scheduler job (overdue-response job code)))))))
    (when completed (run-completion-hook job))))

(defun wait-for-job (scheduler job &key (poll-interval 0.01) on-poll)
  "Block until JOB is done and return its result. ON-POLL is called every
POLL-INTERVAL seconds while waiting (e.g. to detect a client disconnect)."
  (loop
    (sb-thread:with-mutex ((scheduler-lock scheduler))
      (when (eq (job-state job) :done)
        (return (job-result job)))
      (sb-thread:condition-wait (job-done job) (scheduler-lock scheduler)
                                :timeout poll-interval)
      (when (eq (job-state job) :done)
        (return (job-result job))))
    (when on-poll (funcall on-poll))
    (poll-job scheduler job)))

(defun %request-stop (job)
  (when (job-context job)
    (setf (query-context-cancelled (job-context job)) t))
  (unless (job-stop-requested job)
    (setf (job-stop-requested job) (get-internal-real-time))))

(defun cancel-job (scheduler job)
  "Request cancellation of JOB (queued jobs complete immediately)."
  (let ((completed
          (sb-thread:with-mutex ((scheduler-lock scheduler))
            (unless (eq (job-state job) :done)
              (%request-stop job)
              (when (eq (job-state job) :queued)
                (%finish-job scheduler job (overdue-response job "CANCELLED")))))))
    (when completed (run-completion-hook job))))

(defun cancel-query (scheduler query-id)
  "Cancel the active query QUERY-ID. Returns NIL if there is no such query."
  (let ((job (sb-thread:with-mutex ((scheduler-lock scheduler))
               (gethash query-id (scheduler-registry scheduler)))))
    (when job
      (cancel-job scheduler job)
      t)))

(defun cancel-all-jobs (scheduler)
  (dolist (job (sb-thread:with-mutex ((scheduler-lock scheduler))
                 (loop for job being the hash-values of (scheduler-registry scheduler)
                       collect job)))
    (cancel-job scheduler job)))

(defun stop-accepting (scheduler)
  (sb-thread:with-mutex ((scheduler-lock scheduler))
    (setf (scheduler-accepting scheduler) nil)))

(defun scheduler-idle-p (scheduler)
  (sb-thread:with-mutex ((scheduler-lock scheduler))
    (and (zerop (scheduler-running scheduler))
         (zerop (scheduler-queued scheduler))
         (zerop (hash-table-count (scheduler-registry scheduler))))))

(defun scheduler-counts (scheduler)
  "Returns (values running queued)."
  (sb-thread:with-mutex ((scheduler-lock scheduler))
    (values (scheduler-running scheduler) (scheduler-queued scheduler))))

(defun list-active-jobs (scheduler)
  "Snapshot of the active jobs as (query-id state elapsed-ms), oldest first."
  (let ((jobs (sb-thread:with-mutex ((scheduler-lock scheduler))
                (loop for job being the hash-values of (scheduler-registry scheduler)
                      unless (eq (job-state job) :done)
                        collect (list (job-query-id job) (job-state job) (job-submitted job)
                                      (job-elapsed-ms job))))))
    (mapcar (lambda (entry) (list (first entry) (second entry) (fourth entry)))
            (sort jobs #'< :key #'third))))

;;; ------------------------------------------------------------------
;;; Bounded channel (streaming backpressure, protocol.md §7.2)

(defstruct (channel (:constructor make-channel (&optional (capacity 8))))
  (capacity 8 :type (integer 1))
  (lock (sb-thread:make-mutex :name "channel"))
  (changed (sb-thread:make-waitqueue))
  (items '() :type list)                 ; FIFO
  (count 0 :type fixnum))

(defun channel-put (channel item &key (force nil) (on-wait nil))
  "Append ITEM, blocking while the channel is full unless FORCE. ON-WAIT is
called (without the lock) every few milliseconds while blocked, and may
signal to abandon the put (e.g. CHECK-INTERRUPTS)."
  (let ((lock (channel-lock channel)))
    (loop
      (sb-thread:with-mutex (lock)
        (when (or force (< (channel-count channel) (channel-capacity channel)))
          (setf (channel-items channel) (nconc (channel-items channel) (list item)))
          (incf (channel-count channel))
          (sb-thread:condition-broadcast (channel-changed channel))
          (return item))
        (sb-thread:condition-wait (channel-changed channel) lock :timeout 0.005))
      (when on-wait (funcall on-wait)))))

(defun channel-take (channel timeout)
  "Remove and return the oldest item, waiting up to TIMEOUT seconds.
Returns (values item found-p)."
  (let ((lock (channel-lock channel)))
    (sb-thread:with-mutex (lock)
      (when (zerop (channel-count channel))
        (sb-thread:condition-wait (channel-changed channel) lock :timeout timeout))
      (if (plusp (channel-count channel))
          (let ((item (pop (channel-items channel))))
            (decf (channel-count channel))
            (sb-thread:condition-broadcast (channel-changed channel))
            (values item t))
          (values nil nil)))))
