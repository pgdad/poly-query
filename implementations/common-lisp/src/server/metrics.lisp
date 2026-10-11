;;;; metrics.lisp — server counters and their Prometheus text exposition
;;;; (format 0.0.4; protocol.md §7.3).

(in-package #:polyquery)

(defstruct (metrics (:constructor make-metrics ()))
  (lock (sb-thread:make-mutex :name "metrics"))
  (queries-ok 0 :type integer)
  (queries-error 0 :type integer)
  (rejected 0 :type integer)
  (cancelled 0 :type integer)
  (timeouts 0 :type integer)
  (duration-sum 0d0 :type double-float)
  (duration-count 0 :type integer)
  (http-requests 0 :type integer)
  (started (get-internal-real-time)))

(defun record-query-completion (metrics error-code seconds)
  "Count a finished query; ERROR-CODE is NIL for success."
  (sb-thread:with-mutex ((metrics-lock metrics))
    (if error-code
        (incf (metrics-queries-error metrics))
        (incf (metrics-queries-ok metrics)))
    (cond ((equal error-code "CANCELLED") (incf (metrics-cancelled metrics)))
          ((equal error-code "TIMEOUT") (incf (metrics-timeouts metrics))))
    (incf (metrics-duration-sum metrics) (coerce seconds 'double-float))
    (incf (metrics-duration-count metrics))))

(defun record-rejection (metrics)
  (sb-thread:with-mutex ((metrics-lock metrics))
    (incf (metrics-rejected metrics))))

(defun record-http-request (metrics)
  (sb-thread:with-mutex ((metrics-lock metrics))
    (incf (metrics-http-requests metrics))))

(defun format-metric-value (value)
  (if (integerp value)
      (format nil "~D" value)
      (let ((*read-default-float-format* 'double-float))
        (format nil "~,6F" value))))

(defun render-metrics (metrics &key (running 0) (queued 0) (tables 0))
  "The Prometheus text exposition of METRICS plus the given gauges."
  (with-output-to-string (s)
    (flet ((family (name type help samples)
             (format s "# HELP ~A ~A~%# TYPE ~A ~A~%" name help name type)
             (loop for (suffix value) in samples
                   do (format s "~A~A ~A~%" name suffix (format-metric-value value)))))
      (sb-thread:with-mutex ((metrics-lock metrics))
        (family "polyquery_queries_total" "counter" "Queries finished, by outcome."
                `(("{status=\"ok\"}" ,(metrics-queries-ok metrics))
                  ("{status=\"error\"}" ,(metrics-queries-error metrics))))
        (family "polyquery_queries_in_flight" "gauge" "Queries currently executing."
                `(("" ,running)))
        (family "polyquery_queries_queued" "gauge" "Queries waiting for a worker."
                `(("" ,queued)))
        (family "polyquery_queries_rejected_total" "counter" "Queries rejected with OVERLOADED."
                `(("" ,(metrics-rejected metrics))))
        (family "polyquery_queries_cancelled_total" "counter" "Queries that ended CANCELLED."
                `(("" ,(metrics-cancelled metrics))))
        (family "polyquery_queries_timeout_total" "counter" "Queries that ended with TIMEOUT."
                `(("" ,(metrics-timeouts metrics))))
        (family "polyquery_query_duration_seconds" "summary"
                "Query latency from admission to completion."
                `(("_sum" ,(metrics-duration-sum metrics))
                  ("_count" ,(metrics-duration-count metrics))))
        (family "polyquery_http_requests_total" "counter" "HTTP requests received."
                `(("" ,(metrics-http-requests metrics))))
        (family "polyquery_tables" "gauge" "Tables in the catalog."
                `(("" ,tables)))
        (family "polyquery_uptime_seconds" "gauge" "Seconds since the server started."
                `(("" ,(coerce (seconds-since (metrics-started metrics)) 'double-float))))))))
