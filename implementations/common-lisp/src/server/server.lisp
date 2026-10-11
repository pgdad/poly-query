;;;; server.lisp — `serve` mode (protocol.md §7, concurrency.md): the
;;;; listener, one thread per connection, routing of the HTTP API, query
;;;; admission through the scheduler, NDJSON streaming with backpressure,
;;;; client-disconnect detection and graceful shutdown.
;;;;
;;;; Threads: the main thread accepts connections; each connection thread
;;;; parses requests and answers non-query endpoints itself; queries run on
;;;; the scheduler's workers while the connection thread waits for the
;;;; result (or relays streamed batches), watching for client disconnects.

(in-package #:polyquery)

(defstruct server-options
  (host "127.0.0.1")
  (port 0)
  (workers nil)                          ; NIL = number of CPUs
  (queue-depth 64)
  (query-timeout-ms 0)
  (shutdown-grace-ms 10000)
  (max-request-bytes (* 1024 1024 1024)))

(defstruct (server (:constructor %make-server))
  session
  options
  scheduler
  (metrics (make-metrics))
  (lock (sb-thread:make-mutex :name "server"))
  (active-requests 0 :type fixnum)       ; requests being processed right now
  (draining nil))                        ; set once shutdown has begun

(defstruct (connection (:constructor make-connection (socket stream output)))
  socket
  stream                                 ; binary input stream
  output                                 ; HTTP-OUTPUT on the socket
  (gone nil)                             ; the client disconnected
  (peek-buffer (make-array 1 :element-type '(unsigned-byte 8))))

(defconstant +stream-batch-rows+ 1000 "Rows per streamed `rows` line (spec: <= 10,000).")
(defconstant +stream-channel-batches+ 8 "Batches buffered ahead of a slow client (spec: <= 16).")
(defconstant +stream-flush-seconds+ 0.05 "A partial batch older than this is sent anyway.")
(defconstant +stream-socket-buffer+ (* 256 1024)
  "Kernel send buffer of a streaming connection, so that a client that stops
reading stalls the query after a bounded amount of output.")

(sb-ext:defglobal **shutdown-requested** nil)

(defvar *keep-alive* t
  "Whether the connection stays open after the response being produced.")

;;; ------------------------------------------------------------------
;;; Responses

(defparameter *error-http-status*
  '(("PARSE_ERROR" . 400) ("SEMANTIC_ERROR" . 400) ("TYPE_ERROR" . 400)
    ("CONVERSION_ERROR" . 400) ("INVALID_ARGUMENT" . 400) ("INVALID_REQUEST" . 400)
    ("INGEST_ERROR" . 400) ("NUMERIC_OVERFLOW" . 400) ("DIVISION_BY_ZERO" . 400)
    ("SUBQUERY_CARDINALITY" . 400) ("UNSUPPORTED" . 400)
    ("ACCESS_DENIED" . 403)
    ("NOT_FOUND" . 404)
    ("ALREADY_EXISTS" . 409) ("CANCELLED" . 409)
    ("RESOURCE_LIMIT" . 413)
    ("INTERNAL_ERROR" . 500) ("IO_ERROR" . 500) ("STORAGE_CORRUPT" . 500)
    ("STORAGE_VERSION_UNSUPPORTED" . 500)
    ("OVERLOADED" . 503) ("SHUTTING_DOWN" . 503)
    ("TIMEOUT" . 504))
  "Error code -> HTTP status (protocol.md §7.1).")

(defun error-http-status (code)
  (or (cdr (assoc code *error-http-status* :test #'equal)) 500))

(defun response-ok-p (response)
  (eq (json-get response "ok") :true))

(defun response-error-code (response)
  (and (not (response-ok-p response))
       (json-get (json-get response "error") "code")))

(defun response-status (response success-status)
  (if (response-ok-p response)
      success-status
      (error-http-status (response-error-code response))))

(defun send-json (conn status object &optional headers)
  (write-http-response (connection-output conn) status "application/json"
                       (json-to-string object) :headers headers :keep-alive *keep-alive*))

(defun send-response (conn response &key (success-status 200) headers)
  "Send a protocol RESPONSE with the HTTP status its outcome maps to."
  (send-json conn (response-status response success-status) response headers))

(defun send-error (conn code message &key (id :omit) headers (status (error-http-status code)))
  (send-json conn status (error-response id code message) headers))

;;; ------------------------------------------------------------------
;;; Request helpers

(defun request-body-json (request)
  "The request body parsed as JSON. Signals INVALID_REQUEST."
  (let* ((body (or (http-request-body request)
                   (make-array 0 :element-type '(unsigned-byte 8))))
         (text (handler-case (sb-ext:octets-to-string body :external-format :utf-8)
                 (error () (invalid-request-error "request body is not valid UTF-8")))))
    (handler-case (parse-json text)
      (json-syntax-error (e)
        (invalid-request-error "malformed JSON: ~A" (json-syntax-error-message e))))))

(defun request-body-object (request)
  (let ((body (request-body-json request)))
    (unless (json-object-p body)
      (invalid-request-error "request body must be a JSON object"))
    body))

(defun refuse-while-draining (server)
  (when (server-draining server)
    (signal-pq-error "SHUTTING_DOWN" "the server is shutting down")))

(defun connection-closed-p (conn)
  "True if the client has closed (or reset) its side of the connection."
  (or (connection-gone conn)
      (setf (connection-gone conn)
            (handler-case
                (let ((socket (connection-socket conn)))
                  (and (sb-unix:unix-simple-poll (sb-bsd-sockets:socket-file-descriptor socket)
                                                 :input 0)
                       (let ((n (nth-value 1 (sb-bsd-sockets:socket-receive
                                              socket (connection-peek-buffer conn) nil
                                              :peek t :dontwait t))))
                         (and n (zerop n)))))
              (error () t)))))

(defun disconnect-watcher (server conn job)
  "A poll function cancelling JOB once the client of CONN goes away."
  (lambda ()
    (when (connection-closed-p conn)
      (setf *keep-alive* nil)
      (cancel-job (server-scheduler server) job))))

;;; ------------------------------------------------------------------
;;; Queries

(defun query-id-header (job)
  (list (cons "X-PolyQuery-Query-Id" (job-query-id job))))

(defun query-completion-hook (server)
  "Records metrics and the completion log event of a finished job."
  (lambda (job)
    (let* ((result (job-result job))
           (code (response-error-code result))
           (seconds (seconds-since (job-submitted job))))
      (record-query-completion (server-metrics server) code seconds)
      (log-event :info "query finished"
                 "query_id" (job-query-id job)
                 "status" (if code "error" "ok")
                 "duration_ms" (floor (* seconds 1000))
                 "rows" (let ((n (json-get result "row_count"))) (if (integerp n) n 0))
                 "error_code" (or code :omit)))))

(defun effective-timeout-ms (server options)
  "options.timeout_ms if > 0, else the server default (concurrency.md §3)."
  (let ((ms (request-field options "timeout_ms" :type :non-negative-integer)))
    (if (and ms (plusp ms))
        ms
        (server-options-query-timeout-ms (server-options server)))))

(defun make-query-job (server request id thunk-maker)
  "Validate the query REQUEST and create its job (not yet submitted), with
its client-chosen or a fresh query id. THUNK-MAKER is called with the query
context and returns the job's thunk."
  (let* ((session (server-session server))
         (options (or (request-field request "options" :type :object) (jobj)))
         (query-id (request-field options "query_id" :type :string))
         (context (make-context-for session (effective-timeout-ms server options))))
    (request-field request "sql" :required t :type :string)
    (when (and query-id (zerop (length query-id)))
      (invalid-request-error "option query_id must not be empty"))
    (make-job :query-id (or query-id (assign-query-id (server-scheduler server)))
              :request-id id
              :context context
              :thunk (funcall thunk-maker context)
              :on-complete (query-completion-hook server))))

(defun note-admission-failure (server job error)
  "Count and log a query that failed validation or was not admitted."
  (let ((code (pq-error-code error))
        (metrics (server-metrics server)))
    (cond ((string= code "OVERLOADED") (record-rejection metrics))
          ((string= code "SHUTTING_DOWN"))
          (t (record-query-failure metrics)))
    (log-event (if (string= code "OVERLOADED") :warn :info) "query rejected"
               "query_id" (if job (job-query-id job) :omit)
               "status" "error"
               "error_code" code)))

(defun start-query (server conn request id thunk-maker)
  "Validate the query REQUEST and submit its job (see MAKE-QUERY-JOB). On
failure the error response is sent and NIL returned."
  (let ((job nil))
    (handler-case
        (progn
          (setf job (make-query-job server request id thunk-maker))
          (submit-job (server-scheduler server) job))
      (pq-error (e)
        (note-admission-failure server job e)
        (send-response conn (error-response id (pq-error-code e) (pq-error-message e)
                                            (pq-error-details e))
                       :headers (and job (query-id-header job)))
        nil))))

(defun run-query (server conn request id)
  "Execute a query request through the scheduler and send its response."
  (let* ((session (server-session server))
         (job (start-query server conn request id
                           (lambda (context)
                             (lambda ()
                               (with-error-response (id)
                                 (op-query session id request context)))))))
    (when job
      (let ((result (wait-for-job (server-scheduler server) job
                                  :on-poll (disconnect-watcher server conn job))))
        (unless (connection-gone conn)
          (send-response conn result :headers (query-id-header job)))))))

;;; Streaming (protocol.md §7.2). The worker produces items into a bounded
;;; channel: (:header columns), (:rows columns rows)*, then (:end count) or
;;; (:error response). A full channel blocks the worker (backpressure).

(defun produce-stream (session request id context channel)
  "Worker side of a streamed query; returns the job's summary response."
  (let* ((sql (request-field request "sql" :required t :type :string))
         (options (or (request-field request "options" :type :object) (jobj)))
         (max-rows (request-field options "max_rows" :type :non-negative-integer))
         (*query-context* context))
    (validate-query-options options)
    (option-in options "result" '("rows" "count"))
    (with-query-cleanups (context)
      (multiple-value-bind (columns next)
          (open-sql-with-row-fallback session sql (session-exec-options session options))
        (declare (type function next))
        (channel-put channel (list :header columns) :on-wait #'check-interrupts)
        (let ((batch '()) (size 0) (count 0) (batch-start 0)
              (flush-ticks (floor (* +stream-flush-seconds+ internal-time-units-per-second))))
          (declare (type fixnum size count))
          (flet ((flush ()
                   (when batch
                     (channel-put channel (list :rows columns (nreverse batch))
                                  :on-wait #'check-interrupts)
                     (setf batch '() size 0))))
            (loop for row = (funcall next)
                  while row
                  do (incf count)
                     (when (and max-rows (> count max-rows))
                       (resource-limit-error "result exceeds max_rows (~D)" max-rows))
                     (when (zerop size) (setf batch-start (get-internal-real-time)))
                     (push row batch)
                     (incf size)
                     (when (or (>= size +stream-batch-rows+)
                               (> (- (get-internal-real-time) batch-start) flush-ticks))
                       (flush)))
            (flush))
          (channel-put channel (list :end count) :force t)
          (success-response id "row_count" count))))))

(defun stream-query (server conn request id)
  (let* ((session (server-session server))
         (channel (make-channel +stream-channel-batches+))
         (job (start-query server conn request id
                           (lambda (context)
                             (lambda ()
                               (let ((result (with-error-response (id)
                                               (produce-stream session request id
                                                               context channel))))
                                 (unless (response-ok-p result)
                                   (channel-put channel (list :error result) :force t))
                                 result))))))
    (unless job
      (return-from stream-query))
    (ignore-errors
     (setf (sb-bsd-sockets:sockopt-send-buffer (connection-socket conn)) +stream-socket-buffer+))
    (relay-stream server conn job channel)))

(defun job-done-p (scheduler job)
  (sb-thread:with-mutex ((scheduler-lock scheduler))
    (eq (job-state job) :done)))

(defun relay-stream (server conn job channel)
  "Connection side of a streamed query: write channel items as NDJSON chunks."
  (let ((stream (connection-output conn))
        (scheduler (server-scheduler server))
        (watch (disconnect-watcher server conn job))
        (header-sent nil))
    (labels ((emit (object)
               (write-chunk stream (concatenate 'string (json-to-string object)
                                                (string #\Newline))))
             (fail (response)
               (if header-sent
                   (progn (emit (jobj "type" "error" "error" (json-get response "error")))
                          (end-chunked-response stream))
                   (send-response conn response :headers (query-id-header job)))))
      (handler-case
          (loop
            (let ((done-before (job-done-p scheduler job)))
              (multiple-value-bind (item found) (channel-take channel 0.01)
                (cond
                  (found
                   (ecase (first item)
                     (:header
                      (start-chunked-response stream 200 "application/x-ndjson"
                                              :headers (query-id-header job)
                                              :keep-alive *keep-alive*)
                      (setf header-sent t)
                      (emit (jobj "type" "header" "query_id" (job-query-id job)
                                  "columns" (columns-json (second item)))))
                     (:rows
                      (emit (jobj "type" "rows"
                                  "rows" (rows-json-raw (second item) (third item)))))
                     (:end
                      (emit (jobj "type" "end" "row_count" (second item)))
                      (end-chunked-response stream)
                      (return))
                     (:error (fail (second item)) (return))))
                  (done-before
                   ;; completed without a terminal item: cancelled or timed out
                   ;; on the worker's behalf
                   (fail (job-result job))
                   (return))
                  (t
                   (funcall watch)
                   (when (connection-gone conn) (return))
                   (poll-job scheduler job))))))
        ((or stream-error http-write-error sb-bsd-sockets:socket-error) ()
          (setf (connection-gone conn) t *keep-alive* nil)
          (cancel-job scheduler job))))))

;;; ------------------------------------------------------------------
;;; Endpoint handlers. Each sends exactly one response.

(defun handle-health (server conn request)
  (declare (ignore request))
  (if (server-draining server)
      (send-json conn 503 (jobj "status" "shutting_down"))
      (send-json conn 200 (jobj "status" "ok"))))

(defun handle-metrics (server conn request)
  (declare (ignore request))
  (multiple-value-bind (running queued) (scheduler-counts (server-scheduler server))
    (write-http-response (connection-output conn) 200 "text/plain; version=0.0.4; charset=utf-8"
                         (render-metrics (server-metrics server)
                                         :running running :queued queued
                                         :tables (catalog-table-count
                                                  (session-catalog (server-session server))))
                         :keep-alive *keep-alive*)))

(defun handle-version (server conn request)
  (declare (ignore server request))
  (send-json conn 200 (version-response :omit)))

(defun handle-capabilities (server conn request)
  (declare (ignore server request))
  (send-json conn 200 (capabilities-response :omit)))

(defun handle-query (server conn request)
  (refuse-while-draining server)
  (let ((body (request-body-object request)))
    (run-query server conn body (request-id body))))

(defun handle-query-stream (server conn request)
  (refuse-while-draining server)
  (let ((body (request-body-object request)))
    (stream-query server conn body (request-id body))))

(defun handle-explain (server conn request)
  (refuse-while-draining server)
  (let* ((body (request-body-object request))
         (id (request-id body)))
    (send-response conn (with-error-response (id)
                          (dispatch-op (server-session server) "explain" id body)))))

(defun handle-protocol-request (server conn request)
  "POST /v1/request: any protocol request; queries go through admission."
  (refuse-while-draining server)
  (let* ((body (request-body-json request))
         (id (request-id body)))
    (if (and (json-object-p body) (equal (json-get body "op") "query"))
        (run-query server conn body id)
        (send-response conn (handle-request (server-session server) body)))))

(defun handle-list-tables (server conn request)
  (declare (ignore request))
  (send-response conn (with-error-response (:omit) (op-tables (server-session server) :omit))))

(defun handle-table-schema (server conn request name)
  (declare (ignore request))
  (send-response conn (with-error-response (:omit)
                        (op-schema (server-session server) :omit (jobj "table" name)))))

(defun handle-table-stats (server conn request name)
  (declare (ignore request))
  (send-response conn (with-error-response (:omit)
                        (op-stats (server-session server) :omit (jobj "table" name)))))

(defun boolean-param (request name default)
  (let ((value (http-query-param request name)))
    (cond ((null value) default)
          ((string-equal value "true") :true)
          ((string-equal value "false") :false)
          (t (invalid-request-error "query parameter ~A must be true or false" name)))))

(defun handle-put-table (server conn request name)
  "PUT /v1/tables/{name}?format=…: load the raw body as a table."
  (refuse-while-draining server)
  (let* ((format (or (http-query-param request "format")
                     (invalid-request-error "query parameter format is required")))
         (delimiter (http-query-param request "delimiter"))
         (load-request (jobj "table" name
                             "format" format
                             "replace" (boolean-param request "replace" :false)
                             "options" (jobj "header" (boolean-param request "header" :true)
                                             "delimiter" (or delimiter :omit))))
         (body (or (http-request-body request)
                   (make-array 0 :element-type '(unsigned-byte 8)))))
    (send-response conn (with-error-response (:omit)
                          (op-load (server-session server) :omit load-request body))
                   :success-status 201)))

(defun handle-delete-table (server conn request name)
  (declare (ignore request))
  (refuse-while-draining server)
  (send-response conn (with-error-response (:omit)
                        (catalog-drop-table (session-catalog (server-session server)) name)
                        (success-response :omit))))

(defun handle-list-queries (server conn request)
  (declare (ignore request))
  (send-json conn 200
             (success-response :omit
                               "queries"
                               (loop for (query-id state elapsed) in (list-active-jobs
                                                                       (server-scheduler server))
                                     collect (jobj "query_id" query-id
                                                   "state" (string-downcase (symbol-name state))
                                                   "elapsed_ms" elapsed)))))

(defun handle-cancel-query (server conn request query-id)
  (declare (ignore request))
  (if (cancel-query (server-scheduler server) query-id)
      (progn (log-event :info "query cancellation requested" "query_id" query-id)
             (send-json conn 200 (success-response :omit "cancelled" :true)))
      (send-error conn "NOT_FOUND" (format nil "no active query ~S" query-id))))

;;; ------------------------------------------------------------------
;;; Routing

(defun route-request (method segments)
  "Returns (values handler known-path-p allowed-methods). HANDLER is a
function of (server conn request), or NIL if the path or method is unknown."
  (flet ((pick (&rest methods-and-handlers)
           (let ((allowed (loop for (m) on methods-and-handlers by #'cddr collect m)))
             (values (loop for (m h) on methods-and-handlers by #'cddr
                           when (string= m method) return h)
                     t allowed))))
    (let ((n (length segments)))
      (cond
        ((equal segments '("health")) (pick "GET" #'handle-health))
        ((equal segments '("metrics")) (pick "GET" #'handle-metrics))
        ((and (>= n 2) (string= (first segments) "v1"))
         (let ((resource (second segments)) (rest (cddr segments)))
           (cond
             ((and (string= resource "version") (null rest)) (pick "GET" #'handle-version))
             ((and (string= resource "capabilities") (null rest))
              (pick "GET" #'handle-capabilities))
             ((and (string= resource "query") (null rest)) (pick "POST" #'handle-query))
             ((and (string= resource "query") (equal rest '("stream")))
              (pick "POST" #'handle-query-stream))
             ((and (string= resource "explain") (null rest)) (pick "POST" #'handle-explain))
             ((and (string= resource "request") (null rest))
              (pick "POST" #'handle-protocol-request))
             ((and (string= resource "tables") (null rest)) (pick "GET" #'handle-list-tables))
             ((and (string= resource "tables") (= (length rest) 1))
              (let ((name (first rest)))
                (pick "PUT" (lambda (s c r) (handle-put-table s c r name))
                      "DELETE" (lambda (s c r) (handle-delete-table s c r name)))))
             ((and (string= resource "tables") (= (length rest) 2)
                   (member (second rest) '("schema" "stats") :test #'string=))
              (let ((name (first rest)))
                (if (string= (second rest) "schema")
                    (pick "GET" (lambda (s c r) (handle-table-schema s c r name)))
                    (pick "GET" (lambda (s c r) (handle-table-stats s c r name))))))
             ((and (string= resource "queries") (null rest))
              (pick "GET" #'handle-list-queries))
             ((and (string= resource "queries") (= (length rest) 1))
              (let ((query-id (first rest)))
                (pick "DELETE" (lambda (s c r) (handle-cancel-query s c r query-id)))))
             (t (values nil nil nil)))))
        (t (values nil nil nil))))))

(defun dispatch-http-request (server conn request)
  (multiple-value-bind (handler known allowed)
      (route-request (http-request-method request) (http-request-segments request))
    (cond
      (handler
       (handler-case (funcall handler server conn request)
         (pq-error (e)
           ;; raised before any response was written
           (send-error conn (pq-error-code e) (pq-error-message e)))))
      (known
       (send-error conn "INVALID_REQUEST"
                   (format nil "method ~A not allowed for ~A" (http-request-method request)
                           (http-request-path request))
                   :status 405
                   :headers (list (cons "Allow" (format nil "~{~A~^, ~}" allowed)))))
      (t
       (send-error conn "NOT_FOUND" (format nil "no such endpoint ~A" (http-request-path request)))))))

;;; ------------------------------------------------------------------
;;; Connections

(defmacro with-active-request ((server) &body body)
  (let ((s (gensym "SERVER")))
    `(let ((,s ,server))
       (sb-thread:with-mutex ((server-lock ,s)) (incf (server-active-requests ,s)))
       (unwind-protect (progn ,@body)
         (sb-thread:with-mutex ((server-lock ,s)) (decf (server-active-requests ,s)))))))

(defun linger-close (conn)
  "Half-close CONN and discard what the client still sends (briefly), so the
response is not destroyed by a TCP reset when the socket is closed."
  (ignore-errors
   (let* ((socket (connection-socket conn))
          (fd (sb-bsd-sockets:socket-file-descriptor socket))
          (buffer (make-array 65536 :element-type '(unsigned-byte 8)))
          (deadline (+ (get-internal-real-time) internal-time-units-per-second)))
     (sb-bsd-sockets:socket-shutdown socket :direction :output)
     (loop while (and (< (get-internal-real-time) deadline)
                      (sb-unix:unix-simple-poll fd :input 100))
           do (let ((n (nth-value 1 (sb-bsd-sockets:socket-receive socket buffer nil
                                                                    :dontwait t))))
                (when (and n (zerop n)) (return)))))))

(defun serve-one-request (server conn)
  "Read and answer one request on CONN. Returns true to keep the connection."
  (let* ((stream (connection-stream conn))
         (max-bytes (server-options-max-request-bytes (server-options server)))
         (request (handler-case
                      (read-http-request stream max-bytes
                                         :on-continue (lambda ()
                                                        (write-continue (connection-output conn))))
                    (http-protocol-error (e)
                      (let ((*keep-alive* nil))
                        (send-error conn "INVALID_REQUEST" (http-protocol-error-message e)))
                      (return-from serve-one-request nil))
                    (http-body-too-large (e)
                      (let ((*keep-alive* (and (http-body-too-large-drained e)
                                               (not (server-draining server)))))
                        (send-error conn "RESOURCE_LIMIT"
                                    (format nil "request body exceeds ~D bytes" max-bytes))
                        (unless *keep-alive* (linger-close conn))
                        (return-from serve-one-request *keep-alive*))))))
    (when request
      (with-active-request (server)
        (record-http-request (server-metrics server))
        (log-event :debug "http request" "method" (http-request-method request)
                   "path" (http-request-path request))
        (let ((*keep-alive* (and (http-keep-alive-p request) (not (server-draining server)))))
          (dispatch-http-request server conn request)
          (and *keep-alive* (not (connection-gone conn)) (not (server-draining server))))))))

(defun serve-connection (server socket)
  (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
    (unwind-protect
         (handler-case
             (let* ((stream (sb-bsd-sockets:socket-make-stream
                             socket :input t :element-type '(unsigned-byte 8) :buffering :full))
                    (conn (make-connection socket stream
                                           (make-http-output
                                            (sb-bsd-sockets:socket-file-descriptor socket)))))
               (loop while (serve-one-request server conn)))
           ((or stream-error http-write-error sb-bsd-sockets:socket-error) () nil)
           (serious-condition (e)
             (log-message :error "connection handler failed: ~A" e)))
      (ignore-errors (sb-bsd-sockets:socket-close socket :abort t)))))

;;; ------------------------------------------------------------------
;;; Listener and lifecycle

(defun cpu-count ()
  (let ((n (ignore-errors
            (sb-alien:alien-funcall
             (sb-alien:extern-alien "sysconf" (function sb-alien:long sb-alien:int))
             84))))                       ; _SC_NPROCESSORS_ONLN on Linux
    (if (and (integerp n) (plusp n)) n 4)))

(defun resolve-host (host)
  "Returns (values address socket-class) for HOST: a dotted quad, an IPv6
literal (optionally in brackets) or a resolvable name."
  (let ((parts (split-string host #\.))
        (bare (string-trim "[]" host)))
    (cond ((and (= (length parts) 4)
                (every (lambda (p) (and (plusp (length p)) (every #'digit-char-p p)
                                        (<= (parse-integer p) 255)))
                       parts))
           (values (coerce (mapcar #'parse-integer parts) '(vector (unsigned-byte 8)))
                   'sb-bsd-sockets:inet-socket))
          ((find #\: bare)
           (values (sb-bsd-sockets:make-inet6-address bare) 'sb-bsd-sockets:inet6-socket))
          (t
           (values (sb-bsd-sockets:host-ent-address (sb-bsd-sockets:get-host-by-name host))
                   'sb-bsd-sockets:inet-socket)))))

(defun open-listener (host port)
  (multiple-value-bind (address class) (resolve-host host)
    (let ((socket (make-instance class :type :stream :protocol :tcp)))
      (setf (sb-bsd-sockets:sockopt-reuse-address socket) t)
      (sb-bsd-sockets:socket-bind socket address port)
      (sb-bsd-sockets:socket-listen socket 256)
      (setf (sb-bsd-sockets:non-blocking-mode socket) t)
      socket)))

(defun install-shutdown-handlers ()
  (flet ((request-shutdown (signal info context)
           (declare (ignore signal info context))
           (setf **shutdown-requested** t)))
    (sb-sys:enable-interrupt sb-unix:sigterm #'request-shutdown)
    (sb-sys:enable-interrupt sb-unix:sigint #'request-shutdown))
  (sb-sys:enable-interrupt sb-unix:sigpipe :ignore))

(defun accept-connections (server listener)
  "Accept connections until shutdown is requested."
  (let ((fd (sb-bsd-sockets:socket-file-descriptor listener)))
    (loop until **shutdown-requested**
          do (when (sb-unix:unix-simple-poll fd :input 50)
               (let ((socket (handler-case (sb-bsd-sockets:socket-accept listener)
                               (sb-bsd-sockets:socket-error () nil))))
                 (when socket
                   (handler-case
                       (progn
                         (setf (sb-bsd-sockets:non-blocking-mode socket) nil)
                         (setf (sb-bsd-sockets:sockopt-tcp-nodelay socket) t)
                         (sb-thread:make-thread #'serve-connection :name "http-connection"
                                                                   :arguments (list server socket)))
                     (error (e)
                       (log-message :error "cannot serve connection: ~A" e)
                       (ignore-errors (sb-bsd-sockets:socket-close socket :abort t))))))))))

(defun wait-until (predicate seconds)
  "Poll PREDICATE every 10 ms for up to SECONDS. Returns its last value."
  (let ((deadline (+ (get-internal-real-time) (floor (* seconds internal-time-units-per-second)))))
    (loop
      (let ((value (funcall predicate)))
        (when (or value (> (get-internal-real-time) deadline))
          (return value)))
      (sleep 0.01))))

(defun server-quiescent-p (server)
  (and (scheduler-idle-p (server-scheduler server))
       (zerop (sb-thread:with-mutex ((server-lock server)) (server-active-requests server)))))

(defun shutdown-server (server listener)
  "Graceful shutdown (concurrency.md §5)."
  (let ((grace-ms (server-options-shutdown-grace-ms (server-options server))))
    (log-event :info "shutdown started" "grace_ms" grace-ms)
    (setf (server-draining server) t)
    (stop-accepting (server-scheduler server))
    (ignore-errors (sb-bsd-sockets:socket-close listener))
    (unless (wait-until (lambda () (server-quiescent-p server)) (/ grace-ms 1000))
      (log-event :warn "shutdown grace period expired; cancelling queries")
      (cancel-all-jobs (server-scheduler server))
      (wait-until (lambda () (server-quiescent-p server)) 2))
    (log-event :info "server stopped")))

(defun run-server (config options out)
  "The `serve` mode: run the HTTP server until SIGTERM/SIGINT. Returns 0."
  (sb-ext:disable-debugger)
  (install-shutdown-handlers)
  (let* ((workers (or (server-options-workers options) (cpu-count)))
         (listener (handler-case (open-listener (server-options-host options)
                                                (server-options-port options))
                     (error (e)
                       (format *error-output* "polyquery: cannot listen on ~A:~D: ~A~%"
                               (server-options-host options) (server-options-port options) e)
                       (return-from run-server 1))))
         (server (%make-server :session (make-session config)
                               :options options
                               :scheduler (make-scheduler
                                           :workers workers
                                           :queue-depth (server-options-queue-depth options))))
         (port (nth-value 1 (sb-bsd-sockets:socket-name listener))))
    (write-response-line (jobj "event" "listening" "host" (server-options-host options)
                               "port" port)
                         out)
    (log-event :info "listening" "host" (server-options-host options) "port" port
               "workers" workers "queue_depth" (server-options-queue-depth options))
    (accept-connections server listener)
    (shutdown-server server listener)
    0))
