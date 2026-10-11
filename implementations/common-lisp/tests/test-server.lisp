;;;; test-server.lisp — HTTP message parsing, routing, error mapping,
;;;; admission control, cancellation/timeouts, the streaming channel and
;;;; metrics of the `serve` mode.

(in-package #:polyquery-tests)

(defun call-with-octet-input (octets fn)
  "Call FN with a binary input stream over OCTETS (via a temporary file)."
  (uiop:with-temporary-file (:stream out :pathname path :element-type '(unsigned-byte 8)
                             :direction :output)
    (write-sequence octets out)
    (finish-output out)
    (with-open-file (in path :element-type '(unsigned-byte 8))
      (funcall fn in))))

(defun parse-http-text (text &key (max-bytes 1000))
  "Parse TEXT (CRLF line ends written as ~%) as one request. Returns the
request, or the class name of the condition signalled."
  (let ((octets (sb-ext:string-to-octets
                 (with-output-to-string (s)
                   (loop for c across text
                         do (if (char= c #\Newline)
                                (progn (write-char #\Return s) (write-char #\Newline s))
                                (write-char c s))))
                 :external-format :utf-8)))
    (call-with-octet-input
     octets
     (lambda (in)
       (handler-case (polyquery::read-http-request in max-bytes)
         (error (e) (class-name (class-of e))))))))

(defun body-text (request)
  (sb-ext:octets-to-string (polyquery::http-request-body request) :external-format :utf-8))

;;; HTTP parsing

(deftest http.simple-get
    (let ((r (parse-http-text (format nil "GET /v1/tables/my%20t/schema?x=1&y=a+b HTTP/1.1~%Host: h~%~%"))))
      (list (polyquery::http-request-method r)
            (polyquery::http-request-segments r)
            (polyquery::http-query-param r "y")
            (polyquery::http-header r "host")
            (polyquery::http-keep-alive-p r)))
  ("GET" ("v1" "tables" "my t" "schema") "a b" "h" t))

(deftest http.content-length-body
    (body-text (parse-http-text (format nil "POST /v1/query HTTP/1.1~%Content-Length: 6~%~%{\"a\":1}")))
  "{\"a\":1")

(deftest http.chunked-body
    (body-text (parse-http-text
                (format nil "PUT /t HTTP/1.1~%Transfer-Encoding: chunked~%~%3~%a,b~%2;ext~%1,~%0~%~%")))
  "a,b1,")

(deftest http.connection-close
    (list (polyquery::http-keep-alive-p
           (parse-http-text (format nil "GET / HTTP/1.1~%Connection: close~%~%")))
          (polyquery::http-keep-alive-p (parse-http-text (format nil "GET / HTTP/1.0~%~%"))))
  (nil nil))

(deftest http.end-of-input (parse-http-text "") nil)

(deftest http.malformed-request-line
    (parse-http-text (format nil "garbage~%~%"))
  polyquery::http-protocol-error)

(deftest http.body-too-large
    (parse-http-text (format nil "PUT /t HTTP/1.1~%Content-Length: 2000~%~%~A"
                             (make-string 2000 :initial-element #\a)))
  polyquery::http-body-too-large)

(deftest http.header-value-sanitized
    (polyquery::header-safe-value (format nil "a~Cb%" #\Newline))
  "a%0Ab%25")

;;; Routing and status mapping

(defun route (method &rest segments)
  (multiple-value-bind (handler known allowed) (polyquery::route-request method segments)
    (list (and handler t) known allowed)))

(deftest route.known (route "POST" "v1" "query") (t t ("POST")))
(deftest route.wrong-method (route "GET" "v1" "query") (nil t ("POST")))
(deftest route.unknown (route "GET" "v1" "nope") (nil nil nil))
(deftest route.table (route "DELETE" "v1" "tables" "t") (t t ("PUT" "DELETE")))
(deftest route.cancel (route "DELETE" "v1" "queries" "q1") (t t ("DELETE")))

(deftest http-status.mapping
    (mapcar #'polyquery::error-http-status
            '("PARSE_ERROR" "ACCESS_DENIED" "NOT_FOUND" "CANCELLED" "RESOURCE_LIMIT"
              "IO_ERROR" "OVERLOADED" "TIMEOUT"))
  (400 403 404 409 413 500 503 504))

;;; Scheduler

(defun blocking-job (release &key query-id context)
  "A job whose thunk waits until (CAR RELEASE) is true."
  (polyquery::make-job :query-id query-id :request-id :null :context context
                       :thunk (lambda ()
                                (loop until (car release) do (sleep 0.005))
                                (polyquery::success-response :null))))

(defun response-code (response)
  (if (polyquery::response-ok-p response) :ok (polyquery::response-error-code response)))

(defun wait-for-state (job state)
  (loop repeat 400 until (eq (polyquery::job-state job) state) do (sleep 0.005))
  (polyquery::job-state job))

(deftest scheduler.admission
    (let* ((release (list nil))
           (s (polyquery::make-scheduler :workers 1 :queue-depth 1))
           (running (polyquery::submit-job s (blocking-job release :query-id "a")))
           (queued (progn (wait-for-state running :running)
                          (polyquery::submit-job s (blocking-job release)))))
      (prog1 (list (polyquery::job-state queued)
                   (code-of (polyquery::submit-job s (blocking-job release)))
                   (code-of (polyquery::submit-job s (blocking-job release :query-id "a")))
                   (multiple-value-list (polyquery::scheduler-counts s)))
        (setf (car release) t)
        (polyquery::wait-for-job s running)
        (polyquery::wait-for-job s queued)))
  (:queued "OVERLOADED" "ALREADY_EXISTS" (1 1)))

(deftest scheduler.cancel-queued
    (let* ((release (list nil))
           (s (polyquery::make-scheduler :workers 1 :queue-depth 4))
           (running (polyquery::submit-job s (blocking-job release)))
           (queued (polyquery::submit-job s (blocking-job release :query-id "victim"))))
      (prog1 (list (polyquery::cancel-query s "victim")
                   (response-code (polyquery::wait-for-job s queued))
                   (polyquery::cancel-query s "victim"))
        (setf (car release) t)
        (polyquery::wait-for-job s running)))
  (t "CANCELLED" nil))

(deftest scheduler.queued-timeout
    (let* ((release (list nil))
           (s (polyquery::make-scheduler :workers 1 :queue-depth 4))
           (running (polyquery::submit-job s (blocking-job release)))
           (queued (polyquery::submit-job
                    s (blocking-job release
                                    :context (polyquery::make-query-context
                                              :deadline (polyquery::make-deadline 30))))))
      (prog1 (response-code (polyquery::wait-for-job s queued))
        (setf (car release) t)
        (polyquery::wait-for-job s running)))
  "TIMEOUT")

(deftest scheduler.cancel-running
    (let* ((s (polyquery::make-scheduler :workers 1 :queue-depth 0))
           (context (polyquery::make-query-context))
           (job (polyquery::submit-job
                 s (polyquery::make-job
                    :query-id "r" :context context
                    :thunk (lambda ()
                             (polyquery::with-error-response (:null)
                               (let ((polyquery::*query-context* context))
                                 (loop (polyquery::check-interrupts) (sleep 0.001)))))))))
      (wait-for-state job :running)
      (polyquery::cancel-query s "r")
      (list (response-code (polyquery::wait-for-job s job))
            (polyquery::list-active-jobs s)))
  ("CANCELLED" nil))

;;; Streaming channel

(deftest channel.bounded
    (let ((ch (polyquery::make-channel 2))
          (waits 0))
      (polyquery::channel-put ch 1)
      (polyquery::channel-put ch 2)
      ;; a third put blocks until ON-WAIT gives up
      (list (handler-case
                (polyquery::channel-put ch 3 :on-wait (lambda ()
                                                        (when (> (incf waits) 3)
                                                          (error "blocked"))))
              (error () :blocked))
            (polyquery::channel-put ch 4 :force t)
            (loop for (item found) = (multiple-value-list (polyquery::channel-take ch 0))
                  while found collect item)))
  (:blocked 4 (1 2 4)))

;;; Metrics

(deftest metrics.render
    (let ((m (polyquery::make-metrics)))
      (polyquery::record-query-completion m nil 0.5)
      (polyquery::record-query-completion m "TIMEOUT" 1)
      (polyquery::record-rejection m)
      (let ((text (polyquery::render-metrics m :running 2 :queued 1 :tables 3)))
        (loop for line in '("polyquery_queries_total{status=\"ok\"} 1"
                            "polyquery_queries_total{status=\"error\"} 1"
                            "polyquery_queries_in_flight 2"
                            "polyquery_queries_queued 1"
                            "polyquery_queries_rejected_total 1"
                            "polyquery_queries_timeout_total 1"
                            "polyquery_query_duration_seconds_count 2"
                            "polyquery_query_duration_seconds_sum 1.500000"
                            "polyquery_tables 3")
              always (search line text))))
  t)
