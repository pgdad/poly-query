;;;; requests.lisp — protocol request handling (protocol.md §4–§6).
;;;;
;;;; HANDLE-REQUEST maps one parsed JSON request object to one JSON response
;;;; object. It never signals: every failure becomes an error response.

(in-package #:polyquery)

;;; ------------------------------------------------------------------
;;; Logging (stderr only)

(defparameter *log-levels* '(:debug 0 :info 1 :warn 2 :error 3 :off 4))
(defvar *log-level* :info)

(defun log-message (level format-control &rest args)
  (when (and (not (eq *log-level* :off))
             (>= (getf *log-levels* level) (getf *log-levels* *log-level*)))
    (let ((stream *error-output*))
      (write-json (jobj "ts" (format-log-timestamp) "level" (string-downcase (symbol-name level))
                        "msg" (apply #'format nil format-control args))
                  stream)
      (terpri stream)
      (force-output stream))))

(defun format-log-timestamp ()
  (multiple-value-bind (s mi h d mo y) (decode-universal-time (get-universal-time) 0)
    (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0DZ" y mo d h mi s)))

;;; ------------------------------------------------------------------
;;; Request field access

(defun request-field (request key &key (required nil) (type nil) (description nil))
  "Fetch KEY from REQUEST, checking its JSON type (:STRING :INTEGER :BOOLEAN
:OBJECT :ARRAY). Missing optional fields return NIL; JSON null counts as missing."
  (multiple-value-bind (value found) (json-get request key)
    (when (or (not found) (eq value :null))
      (when required (invalid-request-error "missing required field ~S" key))
      (return-from request-field nil))
    (unless (ecase type
              ((nil) t)
              (:string (stringp value))
              (:integer (integerp value))
              (:non-negative-integer (and (integerp value) (>= value 0)))
              (:boolean (member value '(:true :false)))
              (:object (json-object-p value))
              (:array (simple-vector-p value)))
      (invalid-request-error "field ~S must be ~A" key
                             (or description (string-downcase (symbol-name type)))))
    (if (eq type :boolean) (eq value :true) value)))

;;; ------------------------------------------------------------------
;;; Responses

(defun success-response (id &rest keys-and-values)
  (apply #'jobj "id" id "ok" :true keys-and-values))

(defun error-response (id code message &optional details)
  (jobj "id" id "ok" :false
        "error" (apply #'jobj "code" code "message" message
                       (when details
                         (list "details" (%make-json-object details))))))

;;; ------------------------------------------------------------------
;;; Dispatch

(defun handle-request (session request)
  "Execute one protocol REQUEST and return the response object."
  (let ((id (if (json-object-p request) (json-get request "id" :null) :null)))
    (handler-case
        (progn
          (unless (json-object-p request)
            (invalid-request-error "request must be a JSON object"))
          (let ((op (request-field request "op" :required t :type :string)))
            (dispatch-op session op id request)))
      (pq-error (e)
        (error-response id (pq-error-code e) (pq-error-message e) (pq-error-details e)))
      (storage-condition ()
        (error-response id "RESOURCE_LIMIT" "out of memory while processing the request"))
      (error (e)
        (log-message :error "internal error: ~A" e)
        (error-response id "INTERNAL_ERROR"
                        (format nil "internal error: ~A" (type-of e)))))))

(defun dispatch-op (session op id request)
  (let ((config (session-config session)))
    (cond
      ((string= op "version") (version-response id))
      ((string= op "capabilities") (capabilities-response id))
      ((string= op "tables") (op-tables session id))
      ((string= op "schema") (op-schema session id request))
      ((string= op "drop")
       (catalog-drop-table (session-catalog session)
                           (request-field request "table" :required t :type :string))
       (success-response id))
      ((string= op "reset")
       (catalog-reset (session-catalog session))
       (success-response id))
      ((string= op "load") (op-load session id request))
      ((string= op "query") (op-query session id request))
      ((string= op "sleep")
       (unless (engine-config-test-functions config)
         (invalid-request-error "the sleep op requires --enable-test-functions"))
       (let ((ms (request-field request "ms" :required t :type :non-negative-integer)))
         (sleep (/ ms 1000))
         (success-response id)))
      ((string= op "explain")
       (let ((sql (request-field request "sql" :required t :type :string))
             (options (or (request-field request "options" :type :object) (jobj))))
         (validate-query-options options)
         (success-response id "plan" (explain-sql session sql
                                                  :use-indexes (use-indexes-option options)))))
      ((string= op "save") (op-save session id request))
      ((string= op "open") (op-open session id request))
      ((string= op "stats") (op-stats session id request))
      (t (invalid-request-error "unknown op ~S" op)))))

(defun version-response (id)
  (success-response id
                    "engine" "polyquery-common-lisp"
                    "engine_version" *engine-version*
                    "language" "common-lisp"
                    "protocol_version" *protocol-version*
                    "spec_version" *spec-version*
                    "runtime" (format nil "~A ~A" (lisp-implementation-type)
                                      (lisp-implementation-version))
                    "build" (jobj "profile" "release" "flags" "(optimize (speed 1) (safety 1))")))

(defun capabilities-response (id)
  (success-response id "protocol_version" *protocol-version* "capabilities" *capabilities*))

(defun find-table-or-404 (session name)
  (or (catalog-find-table (session-catalog session) name)
      (signal-pq-error "NOT_FOUND" "table ~A not found" name)))

(defun op-tables (session id)
  (success-response id "tables"
                    (loop for tb in (catalog-list-tables (session-catalog session))
                          collect (jobj "name" (table-name tb) "row_count" (table-row-count tb)))))

(defun op-schema (session id request)
  (let ((table (find-table-or-404 session (request-field request "table" :required t :type :string))))
    (success-response id
                      "table" (table-name table)
                      "row_count" (table-row-count table)
                      "columns" (columns-json (table-columns table))
                      "indexes" (mapcar #'table-index-json
                                        (catalog-table-indexes (session-catalog session) table))
                      "layout" (table-layout-name table))))

(defun op-stats (session id request)
  (let ((table (find-table-or-404 session (request-field request "table" :required t :type :string)))
        (*query-context* (make-context-for session nil)))
    (apply #'success-response id (table-stats-json table))))

;;; ------------------------------------------------------------------
;;; query

(defun option-in (options key allowed)
  "Validate an enumerated string option; unknown values are UNSUPPORTED."
  (let ((v (request-field options key :type :string)))
    (when (and v (not (member v allowed :test #'string=)))
      (unsupported-error "unsupported value ~S for option ~A" v key))
    v))

(defun validate-query-options (options)
  "Check the execution options shared by query and explain (protocol.md §5.2)."
  (option-in options "mode" '("auto" "row"))
  (option-in options "join" '("auto" "hash" "merge" "nested_loop"))
  (let ((threads (request-field options "threads" :type :integer)))
    (when (and threads (< threads 1))
      (invalid-request-error "option threads must be >= 1")))
  (request-field options "optimize" :type :boolean)
  (use-indexes-option options)
  (request-field options "native" :type :boolean)
  (request-field options "query_id" :type :string))

(defun use-indexes-option (options)
  (if (nth-value 1 (json-get options "use_indexes"))
      (request-field options "use_indexes" :type :boolean)
      t))

(defun op-query (session id request)
  (let* ((sql (request-field request "sql" :required t :type :string))
         (options (or (request-field request "options" :type :object) (jobj)))
         (max-rows (request-field options "max_rows" :type :non-negative-integer))
         (timeout-ms (request-field options "timeout_ms" :type :non-negative-integer))
         (result-mode (or (option-in options "result" '("rows" "count")) "rows")))
    (validate-query-options options)
    (let* ((start (get-internal-real-time))
           (count-only (string= result-mode "count"))
           (result (execute-sql session sql :max-rows max-rows :timeout-ms timeout-ms
                                            :collect-rows (not count-only)
                                            :use-indexes (use-indexes-option options)))
           (elapsed-us (floor (* (- (get-internal-real-time) start) 1000000)
                              internal-time-units-per-second)))
      (success-response id
                        "columns" (columns-json (query-result-columns result))
                        "rows" (if count-only :omit (rows-json result))
                        "row_count" (query-result-row-count result)
                        "stats" (jobj "elapsed_us" elapsed-us)))))

(defun rows-json (result)
  "A JSON-RAW writing the result rows with type-directed serialization."
  (let ((types (coerce (mapcar #'column-def-type (query-result-columns result)) 'simple-vector))
        (rows (query-result-rows result)))
    (make-json-raw
     (lambda (stream)
       (write-char #\[ stream)
       (loop for first = t then nil
             for row in rows
             do (unless first (write-char #\, stream))
                (write-char #\[ stream)
                (dotimes (k (length types))
                  (unless (zerop k) (write-char #\, stream))
                  (write-value (svref row k) (svref types k) stream))
                (write-char #\] stream))
       (write-char #\] stream)))))

;;; ------------------------------------------------------------------
;;; load

(defun resolve-data-path (config path)
  "Resolve a request path inside the data directory (protocol.md §6)."
  (when (or (zerop (length path))
            (char= (char path 0) #\/)
            (find (code-char 0) path)
            (member ".." (split-string path #\/) :test #'string=))
    (signal-pq-error "ACCESS_DENIED" "path ~S is not permitted" path))
  (concatenate 'string (engine-config-data-dir config) path))

(defun read-file-octets (native-path max-bytes)
  (handler-case
      (with-open-file (in (sb-ext:parse-native-namestring native-path)
                          :element-type '(unsigned-byte 8))
        (let ((size (file-length in)))
          (when (> size max-bytes)
            (resource-limit-error "input of ~D bytes exceeds the ingestion limit" size))
          (let* ((buf (make-array size :element-type '(unsigned-byte 8)))
                 (n (read-sequence buf in)))
            (if (= n size) buf (subseq buf 0 n)))))
    (file-error ()
      (if (probe-file (sb-ext:parse-native-namestring native-path))
          (signal-pq-error "IO_ERROR" "cannot read ~A" native-path)
          (signal-pq-error "NOT_FOUND" "file not found")))
    (stream-error ()
      (signal-pq-error "IO_ERROR" "cannot read input file"))))

(defun octets-to-text (octets)
  "Decode UTF-8 OCTETS, ignoring a leading BOM."
  (let ((start (if (and (>= (length octets) 3) (= (aref octets 0) #xEF)
                        (= (aref octets 1) #xBB) (= (aref octets 2) #xBF))
                   3 0)))
    (handler-case (sb-ext:octets-to-string octets :start start :external-format :utf-8)
      (error () (ingest-error "input is not valid UTF-8")))))

(defun parse-schema-field (schema)
  "Parse the explicit schema array into a list of COLUMN-DEFs."
  (loop for item across schema
        collect (progn
                  (unless (json-object-p item)
                    (invalid-request-error "schema entries must be objects"))
                  (make-column-def
                   (request-field item "name" :required t :type :string)
                   (parse-type-string (request-field item "type" :required t :type :string)
                                      "INVALID_REQUEST")))))

(defun op-load (session id request)
  (let* ((config (session-config session))
         (name (request-field request "table" :required t :type :string))
         (format-name (request-field request "format" :required t :type :string))
         (format (cond ((string= format-name "csv") :csv)
                       ((string= format-name "json") :json)
                       ((string= format-name "jsonl") :jsonl)
                       (t (invalid-request-error "unknown format ~S" format-name))))
         (path (request-field request "path" :type :string))
         (data (request-field request "data" :type :string))
         (schema-json (request-field request "schema" :type :array))
         (options (or (request-field request "options" :type :object) (jobj)))
         (replace (request-field request "replace" :type :boolean))
         (header (if (nth-value 1 (json-get options "header"))
                     (request-field options "header" :type :boolean)
                     t))
         (delimiter (let ((d (request-field options "delimiter" :type :string)))
                      (cond ((null d) #\,)
                            ((and (= (length d) 1) (< (char-code (char d 0)) 128)
                                  (not (find (char d 0) (list #\" #\Newline #\Return))))
                             (char d 0))
                            (t (invalid-request-error "delimiter must be a single ASCII character")))))
         (schema (when schema-json (parse-schema-field schema-json)))
         (layout (layout-option options))
         (dictionary (if (nth-value 1 (json-get options "dictionary"))
                         (request-field options "dictionary" :type :boolean)
                         :auto)))
    (when (zerop (length name))
      (invalid-request-error "table name must not be empty"))
    (when (or (and path data) (and (null path) (null data)))
      (invalid-request-error "exactly one of path or data is required"))
    (when (and (eq format :csv) (not header) (null schema))
      (invalid-request-error "header=false requires an explicit schema"))
    (when (and (not replace) (catalog-table-exists-p (session-catalog session) name))
      (signal-pq-error "ALREADY_EXISTS" "table ~A already exists" name))
    (let* ((max-bytes (engine-config-max-ingest-bytes config))
           (octets (if path
                       (read-file-octets (resolve-data-path config path) max-bytes)
                       (sb-ext:string-to-octets data :external-format :utf-8)))
           (spec (make-ingest-spec :table-name name :format format :schema schema
                                   :header header :delimiter delimiter
                                   :max-rows (engine-config-max-table-rows config))))
      (when (> (length octets) max-bytes)
        (resource-limit-error "input exceeds the ingestion limit of ~D bytes" max-bytes))
      (let ((table (load-table session spec
                               (if (eq format :csv) octets (octets-to-text octets))
                               :replace replace :layout layout :dictionary dictionary)))
        (success-response id
                          "table" (table-name table)
                          "row_count" (table-row-count table)
                          "columns" (columns-json (table-columns table)))))))

(defun layout-option (options)
  "The table layout requested by a load/open \"layout\" option."
  (let ((layout (request-field options "layout" :type :string)))
    (cond ((null layout) :column)
          ((string= layout "column") :column)
          ((string= layout "row") :row)
          (t (invalid-request-error "unknown layout ~S (expected \"row\" or \"column\")" layout)))))

;;; ------------------------------------------------------------------
;;; save / open (protocol.md §5.7)

(defun op-save (session id request)
  (let* ((config (session-config session))
         (name (request-field request "table" :required t :type :string))
         (path (request-field request "path" :required t :type :string))
         (options (or (request-field request "options" :type :object) (jobj)))
         (row-group-size (or (request-field options "row_group_size" :type :integer)
                             *default-row-group-size*))
         (encoding-name (or (request-field options "encoding" :type :string) "auto"))
         (encoding (cond ((string= encoding-name "auto") :auto)
                         ((string= encoding-name "plain") :plain)
                         ((string= encoding-name "dict") :dict)
                         ((string= encoding-name "rle") :rle)
                         (t (invalid-request-error "unknown encoding ~S" encoding-name))))
         (native (resolve-data-path config path)))
    (unless (plusp row-group-size)
      (invalid-request-error "row_group_size must be positive"))
    (unless (catalog-table-exists-p (session-catalog session) name)
      (signal-pq-error "NOT_FOUND" "table ~A not found" name))
    (let ((bytes (save-table session name native :row-group-size row-group-size
                                                 :encoding encoding)))
      (success-response id "path" path "bytes" bytes))))

(defun op-open (session id request)
  (let* ((config (session-config session))
         (name (request-field request "table" :required t :type :string))
         (path (request-field request "path" :required t :type :string))
         (options (or (request-field request "options" :type :object) (jobj)))
         (mmap (request-field options "mmap" :type :boolean))
         (layout (layout-option options))
         (replace (request-field request "replace" :type :boolean))
         (native (resolve-data-path config path)))
    (when (zerop (length name))
      (invalid-request-error "table name must not be empty"))
    (let ((table (open-table session name native :replace replace :mmap mmap :layout layout)))
      (success-response id
                        "table" (table-name table)
                        "row_count" (table-row-count table)
                        "columns" (columns-json (table-columns table))))))
