;;;; test-memory.lisp — streaming ingestion, column builders and the heap guard.

(in-package #:polyquery-tests)

;;; ------------------------------------------------------------------
;;; Column builders

(defun built-values (type values &key (dictionary :auto))
  "Values read back from a column store built by a COLUMN-BUILDER."
  (let ((b (polyquery::make-column-builder type :dictionary dictionary)))
    (map nil (lambda (v) (polyquery::builder-append-value b v)) values)
    (polyquery::column-store-values (polyquery::finish-column-builder b))))

(deftest builders.agree-with-build-column-store
    (loop for (type . values) in *sample-columns*
          always (loop for dict in '(nil t :auto)
                       always (and (equalp (built-values type values :dictionary dict) values)
                                   (eq (type-of (polyquery::build-column-store
                                                 values type :dictionary dict))
                                       (type-of (let ((b (polyquery::make-column-builder
                                                          type :dictionary dict)))
                                                  (map nil (lambda (v)
                                                             (polyquery::builder-append-value b v))
                                                       values)
                                                  (polyquery::finish-column-builder b)))))))
  t)

(deftest builders.chunk-boundaries
    ;; more rows than one chunk, NULLs on both sides of the boundaries
    (let* ((n (+ (* 2 polyquery::+builder-chunk-size+) 17))
           (values (coerce (loop for i below n
                                 collect (if (zerop (mod i 7919)) :null i))
                           'simple-vector)))
      (equalp (built-values :int64 values) values))
  t)

(deftest builders.dictionary-decision
    ;; the same rule as BUILD-COLUMN-STORE: dictionary below n/2 distinct values
    (flet ((store-kind (values)
             (type-of (let ((b (polyquery::make-column-builder :string)))
                        (map nil (lambda (v) (polyquery::builder-append-value b v)) values)
                        (polyquery::finish-column-builder b)))))
      (list (store-kind (loop for i below 100 collect (format nil "v~D" (mod i 10))))
            (store-kind (loop for i below 100 collect (format nil "v~D" i)))
            (store-kind (loop for i below 10 collect "x"))))
  (polyquery::dict-column polyquery::string-column polyquery::string-column))

(deftest builders.interner-octets-and-strings
    (let ((interner (polyquery::make-string-interner))
          (octets (sb-ext:string-to-octets "abcabd" :external-format :utf-8)))
      (list (polyquery::intern-ascii-octets interner octets 0 3)
            (polyquery::intern-string interner "abc")
            (polyquery::intern-ascii-octets interner octets 3 6)
            (loop for i below 1000 do (polyquery::intern-string interner (format nil "k~D" i))
                  finally (return (polyquery::intern-string interner "abd")))
            (polyquery::intern-ascii-octets interner octets 0 0)))
  (0 0 1 1 1002))

;;; ------------------------------------------------------------------
;;; Streaming CSV: files read in blocks of any size agree with in-memory input

(defparameter *tricky-csv*
  (format nil "~Cid,s,d,f~C~%1,plain,1.50,2.5~%~%2,\"quo\"\"ted, with comma\",-0.25,-0~C~%~C~%3,\"multi~%line\",,1e3~%4,\"\",7,~%5,  pad  ,\" 8.1 \",.5~%6,ünï,10,3.~%7,\"ê\"\"\",0.01,123456789012345678901"
          (code-char #xFEFF) #\Return #\Return #\Return))

(defun temp-file-with (text)
  (let ((path (format nil "/tmp/pq-test-~D-~D.csv" (sb-posix:getpid) (random 1000000))))
    (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                              :if-exists :supersede)
      (write-sequence (sb-ext:string-to-octets text :external-format :utf-8) out))
    path))

(defun ingest-result (input schema)
  "(defs-as-strings values-per-column) or the error code."
  (handler-case
      (multiple-value-bind (defs stores rows)
          (polyquery::ingest-csv input (polyquery::make-ingest-spec :schema schema))
        (list rows
              (mapcar (lambda (d) (type-name-string (polyquery::column-def-type d))) defs)
              (mapcar #'polyquery::column-store-values stores)))
    (pq-error (e) (list (pq-error-code e) (polyquery::pq-error-details e)))))

(defun streaming-agrees-p (text &optional schema)
  (let* ((octets (sb-ext:string-to-octets text :external-format :utf-8))
         (expected (ingest-result octets schema))
         (path (temp-file-with text)))
    (unwind-protect
         (loop for size in '(1 2 3 5 7 16 64 4096)
               always (equalp (let ((polyquery::*csv-block-size* size))
                                (ingest-result path schema))
                              expected))
      (delete-file path))))

(deftest csv-stream.block-boundaries-inferred
    (streaming-agrees-p *tricky-csv*)
  t)

(deftest csv-stream.block-boundaries-explicit
    (streaming-agrees-p *tricky-csv*
                        (list (polyquery::make-column-def "id" :int64)
                              (polyquery::make-column-def "s" :string)
                              (polyquery::make-column-def "d" (parse-type-string "DECIMAL(10,2)" "INVALID_REQUEST"))
                              (polyquery::make-column-def "f" :float64)))
  t)

(deftest csv-stream.errors-agree
    (every #'streaming-agrees-p
           (list (format nil "a,b~%1,2~%3~%")             ; field count
                 (format nil "a~%\"x~%")                  ; unterminated quote
                 (format nil "a~%\"x\"y~%")               ; character after the closing quote
                 (format nil "a,a~%1,2~%")))              ; duplicate names
  t)

(deftest csv-stream.fast-paths-agree-with-text-conversion
    ;; every text accepted by FAST-CONVERT converts to the same value through TEXT-TO-VALUE
    (let ((types (list :int64 :float64 :boolean :date :timestamp (parse-type-string "DECIMAL(12,2)" "INVALID_REQUEST")
                       (parse-type-string "DECIMAL(4,0)" "INVALID_REQUEST")))
          (texts '("0" "-0" "+7" "123456789012345678" "1.5" "-.25" "3." "0.001" "99.99"
                   "9999" "10000" "-9999.4" "1e5" "TRUE" "False" "tru" "12.345" "" "." "+-1"
                   "999999999999999" "0.000000000000000001" "-0.0"
                   "2024-02-29" "2023-02-29" "0000-01-01" "2024-13-01" "2024-1-01" "2024-01-01 10:00:00"
                   "2024-01-01T23:59:59.5" "2024-01-01 23:59:59.123456" "2024-01-01 23:59:59.1234567"
                   "2024-01-01 24:00:00" "2024-01-01 10:00:00." "2024-01-01x10:00:00" "9999-12-31 00:60:00")))
      (loop for type in types
            always (loop for text in texts
                         for octets = (sb-ext:string-to-octets text :external-format :utf-8)
                         for fast = (and (plusp (length text))
                                         (polyquery::fast-convert octets 0 (length octets) type))
                         always (or (null fast)
                                    (multiple-value-bind (v status) (polyquery::text-to-value text type)
                                      (and (eq status :ok)
                                           (eql v (case fast (:true t) (:false nil) (t fast)))))))))
  t)

(deftest csv-stream.conversion-error-precedence
    ;; conversion errors are reported for the leftmost failing column, after
    ;; structural errors anywhere in the input
    (list (second (ingest-result (sb-ext:string-to-octets (format nil "a,b~%1,x~%y,2~%"))
                                 (list (polyquery::make-column-def "a" :int64)
                                       (polyquery::make-column-def "b" :int64))))
          (first (ingest-result (sb-ext:string-to-octets (format nil "a,b~%1,x~%3~%"))
                                (list (polyquery::make-column-def "a" :int64)
                                      (polyquery::make-column-def "b" :int64)))))
  ((("record" . 3) ("column_name" . "a")) "INGEST_ERROR"))

;;; ------------------------------------------------------------------
;;; Heap guard

(deftest heap-guard.resource-limit
    (list (let ((polyquery::*heap-limit* 1)
                (polyquery::*consed-at-last-reclaim* (sb-ext:get-bytes-consed)))
            (code-of (polyquery::check-heap)))
          (let ((polyquery::*heap-limit* (* 1024 1024 1024 1024)))
            (code-of (polyquery::check-heap))))
  ("RESOURCE_LIMIT" :no-error))

(deftest heap-guard.load-fails-and-engine-continues
    (let ((session (make-session (make-engine-config :data-dir "/nonexistent/")))
          (data (with-output-to-string (s)
                  (format s "a,b~%")
                  (dotimes (i 400000) (format s "~D,v~D~%" i i)))))
      (sb-ext:gc :full t)
      (list (let ((polyquery::*heap-limit* (+ (sb-kernel:dynamic-usage) (* 4 1024 1024))))
              (polyquery::json-get
               (polyquery::json-get (handle-request session (jobj "op" "load" "table" "t"
                                                                  "format" "csv" "data" data))
                                    "error")
                                    "code"))
            (polyquery::json-get (handle-request session (jobj "op" "tables")) "tables")
            (polyquery::query-result-rows (execute-sql session "SELECT 1"))))
  ("RESOURCE_LIMIT" nil (#(1))))
