;;;; engine.lisp — the engine facade: configuration, sessions, SQL execution
;;;; pipeline (lex -> parse -> bind -> plan -> execute), index statements,
;;;; table loading and PQCF save/open.

(in-package #:polyquery)

(defparameter *capabilities*
  '("phase1" "ingest.csv" "ingest.json" "ingest.jsonl" "sql.basic" "test.functions"
    "phase2" "sql.groupby" "sql.join" "sql.functions" "sql.subquery" "sql.cte"
    "sql.correlated_subquery"
    "phase3" "storage.pqcf" "storage.mmap" "index.hash" "index.btree"))

(defstruct engine-config
  (data-dir nil)                         ; pathname of the data directory (with trailing /)
  (test-functions nil)
  (max-query-memory-mb 2048)
  (max-ingest-bytes (* 4 1024 1024 1024))
  (max-table-rows 200000000)
  (max-join-rows 100000000)
  (threads 1)
  (log-level :info))

(defstruct (session (:constructor make-session (config)))
  config
  (catalog (make-catalog)))

;;; ------------------------------------------------------------------
;;; Queries

(defstruct query-result
  columns                                ; list of COLUMN-DEF
  rows                                   ; list of SIMPLE-VECTORs
  (row-count 0))

(defun make-context-for (session timeout-ms)
  (let ((config (session-config session)))
    (make-query-context
     :deadline (make-deadline timeout-ms)
     :memory-budget (* (engine-config-max-query-memory-mb config) 1024 1024)
     :max-join-rows (engine-config-max-join-rows config))))

(defun plan-statement (session ast use-indexes)
  "Analyse and plan the query statement AST. Returns (values plan bound-query)."
  (let ((bound (bind-statement ast (session-catalog session)
                               :test-functions (engine-config-test-functions
                                                (session-config session)))))
    (let ((*planning-catalog* (session-catalog session))
          (*use-indexes* use-indexes))
      (values (plan-bound-query bound) bound))))

(defun result-columns (bound)
  (loop for c in (bound-query-columns bound)
        collect (make-column-def (column-def-name c) (output-type (column-def-type c)))))

(defun statement-result ()
  (make-query-result :columns '() :rows '() :row-count 0))

(defun execute-sql (session sql &key max-rows timeout-ms (collect-rows t) (use-indexes t))
  "Run SQL against the session catalog and return a QUERY-RESULT."
  (let ((*query-context* (make-context-for session timeout-ms))
        (ast (parse-sql sql)))
    (typecase ast
      (ast-create-index (execute-create-index session ast) (statement-result))
      (ast-drop-index (execute-drop-index session ast) (statement-result))
      (t
       (multiple-value-bind (plan bound) (plan-statement session ast use-indexes)
         (if (ast-explain-p ast)
             (make-query-result :columns (list (make-column-def "plan" :string))
                                :rows (list (vector (json-to-string (explain-plan-json plan))))
                                :row-count 1)
             (run-plan plan bound max-rows collect-rows)))))))

(defun run-plan (plan bound max-rows collect-rows)
  (let* ((columns (result-columns bound))
         (next (funcall (the function (compile-plan plan))))
         (width (length columns))
         (rows '())
         (count 0))
    (declare (type function next) (type fixnum count))
    (loop for row = (funcall next)
          while row
          do (incf count)
             (when (and max-rows (> count max-rows))
               (resource-limit-error "result exceeds max_rows (~D)" max-rows))
             (when collect-rows
               (when (zerop (mod count +interrupt-check-interval+))
                 (charge-memory (* +interrupt-check-interval+ (row-footprint width))))
               (push row rows)))
    (make-query-result :columns columns
                       :rows (nreverse rows)
                       :row-count count)))

(defun explain-sql (session sql &key (use-indexes t))
  "The EXPLAIN plan JSON of the query SQL (an EXPLAIN prefix is accepted)."
  (let ((*query-context* (make-context-for session nil))
        (ast (parse-sql sql)))
    (when (typep ast '(or ast-create-index ast-drop-index))
      (signal-pq-error "INVALID_REQUEST" "only queries can be explained"))
    (explain-plan-json (plan-statement session ast use-indexes))))

;;; ------------------------------------------------------------------
;;; Index statements

(defun execute-create-index (session ast)
  (let* ((catalog (session-catalog session))
         (name (ast-create-index-name ast))
         (table (or (catalog-find-table catalog (ast-create-index-table ast))
                    (bind-error-at ast "SEMANTIC_ERROR" "unknown table ~A"
                                   (ast-create-index-table ast))))
         (column (or (find-column-index table (ast-create-index-index-column ast))
                     (bind-error-at ast "SEMANTIC_ERROR" "unknown column ~A in table ~A"
                                    (ast-create-index-index-column ast) (table-name table)))))
    (if (catalog-find-index catalog name)
        (unless (ast-create-index-if-not-exists ast)
          (signal-pq-error "ALREADY_EXISTS" "index ~A already exists" name))
        (handler-case
            (catalog-add-index catalog (build-table-index name table column
                                                          (ast-create-index-kind ast)))
          (pq-error (e)
            ;; Lost a race with a concurrent CREATE INDEX of the same name.
            (unless (and (ast-create-index-if-not-exists ast)
                         (string= (pq-error-code e) "ALREADY_EXISTS"))
              (error e)))))))

(defun execute-drop-index (session ast)
  (let ((catalog (session-catalog session))
        (name (ast-drop-index-name ast)))
    (if (catalog-find-index catalog name)
        (handler-case (catalog-drop-index catalog name)
          (pq-error (e) (unless (ast-drop-index-if-exists ast) (error e))))
        (unless (ast-drop-index-if-exists ast)
          (signal-pq-error "NOT_FOUND" "index ~A not found" name)))))

;;; ------------------------------------------------------------------
;;; Loading

(defun load-table (session spec source &key replace (layout :column) (dictionary :auto))
  "Create a table from SOURCE (octets for CSV, a string for JSON/JSONL) per the
INGEST-SPEC and publish it atomically. Returns the new table."
  (multiple-value-bind (defs data row-count)
      (ecase (ingest-spec-format spec)
        (:csv (ingest-csv source spec))
        ((:json :jsonl) (ingest-json source spec)))
    (catalog-add-table (session-catalog session)
                       (make-table (ingest-spec-table-name spec) defs data row-count
                                   :layout layout :dictionary dictionary)
                       :replace replace)))

;;; ------------------------------------------------------------------
;;; Persistent storage

(defun save-table (session name native-path &key (row-group-size *default-row-group-size*)
                                                  (encoding :auto))
  "Write table NAME atomically as a PQCF file. Returns the file size."
  (let* ((catalog (session-catalog session))
         (table (or (catalog-find-table catalog name)
                    (signal-pq-error "NOT_FOUND" "table ~A not found" name)))
         (indexes (catalog-table-indexes catalog table))
         (*query-context* (make-context-for session nil)))
    (write-file-atomically native-path
                           (lambda (stream)
                             (write-pqcf stream table indexes :row-group-size row-group-size
                                                              :encoding encoding)))))

(defun open-table (session name native-path &key replace mmap (layout :column))
  "Open the PQCF file as table NAME, recreating the indexes its metadata
lists. The catalog is only changed if everything succeeds."
  (let ((catalog (session-catalog session))
        (*query-context* (make-context-for session nil)))
    (when (and (not replace) (catalog-table-exists-p catalog name))
      (signal-pq-error "ALREADY_EXISTS" "table ~A already exists" name))
    (multiple-value-bind (table index-specs)
        (load-pqcf-table native-path name :mmap mmap :layout layout)
      (let ((indexes (loop for (index-name column-name kind) in index-specs
                           collect (build-table-index index-name table
                                                      (find-column-index table column-name)
                                                      kind))))
        (catalog-add-table catalog table :replace replace :indexes indexes)))))
