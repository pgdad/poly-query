;;;; test-ingest.lisp — CSV and JSON ingestion.

(in-package #:polyquery-tests)

(defun load-and-describe (format data &rest extra)
  "Load DATA into a fresh session; return (columns-types rows) or the error code."
  (let* ((session (make-session (make-engine-config :data-dir "/nonexistent/")))
         (resp (handle-request session
                               (apply #'jobj "op" "load" "table" "t" "format" format "data" data extra))))
    (if (eq (polyquery::json-get resp "ok") :true)
        (let ((result (execute-sql session "SELECT * FROM t")))
          (list (mapcar (lambda (c) (type-name-string (polyquery::column-def-type c)))
                        (polyquery::query-result-columns result))
                (mapcar (lambda (r) (coerce r 'list)) (polyquery::query-result-rows result))))
        (values (polyquery::json-get (polyquery::json-get resp "error") "code")))))

(deftest csv.infer
    (first (load-and-describe "csv" (format nil "b,i,f,d,t,s~%true,1,1,2024-01-01,2024-01-01,x~%FALSE,-2,2.5,2024-01-02,2024-01-02 10:00:00,y~%")))
  ("BOOLEAN" "INT64" "FLOAT64" "DATE" "TIMESTAMP" "STRING"))

(deftest csv.quoting
    (second (load-and-describe "csv" (format nil "s~%\"a,b\"~%\"q\"\"q\"~%\"\"~%~%x~%")))
  (("a,b") ("q\"q") ("") ("x")))

(deftest csv.null-vs-empty
    (second (load-and-describe "csv" (format nil "n,s~%,~%\"\",\"\"~%1,x~%")))
  ((:null :null) (:null "") (1 "x")))

(deftest csv.crlf (second (load-and-describe "csv" (format nil "a~C~%1~C~%" #\Return #\Return)))
  ((1)))

(deftest csv.arity (load-and-describe "csv" (format nil "a,b~%1~%")) "INGEST_ERROR")
(deftest csv.duplicate (load-and-describe "csv" (format nil "a,A~%1,2~%")) "INGEST_ERROR")
(deftest csv.bad-quote (load-and-describe "csv" (format nil "a~%\"x~%")) "INGEST_ERROR")

(deftest csv.decimal-schema
    (load-and-describe "csv" (format nil "v~%1.005~%")
                       "schema" (vector (jobj "name" "v" "type" "DECIMAL(10,2)")))
  "CONVERSION_ERROR")

(deftest json.infer
    (first (load-and-describe "jsonl" (format nil "{\"a\":1,\"b\":1.5,\"c\":\"2024-01-01\",\"d\":true}~%{\"a\":2,\"b\":2,\"c\":\"2024-01-01T10:00:00\"}~%")))
  ("INT64" "FLOAT64" "TIMESTAMP" "BOOLEAN"))

(deftest json.mixed (load-and-describe "json" "[{\"a\":1},{\"a\":\"x\"}]") "INGEST_ERROR")
(deftest json.nested (load-and-describe "jsonl" "{\"a\":{\"b\":1}}") "INGEST_ERROR")
(deftest json.not-array (load-and-describe "json" "{\"a\":1}") "INGEST_ERROR")
