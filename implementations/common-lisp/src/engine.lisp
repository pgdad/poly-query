;;;; engine.lisp — the engine facade: configuration, sessions, SQL execution
;;;; pipeline (lex -> parse -> bind -> plan -> execute), index statements,
;;;; table loading and PQCF save/open.

(in-package #:polyquery)

(defparameter *capabilities*
  '("phase1" "ingest.csv" "ingest.json" "ingest.jsonl" "sql.basic" "test.functions"
    "phase2" "sql.groupby" "sql.join" "sql.functions" "sql.subquery" "sql.cte"
    "sql.correlated_subquery"
    "phase3" "storage.pqcf" "storage.mmap" "index.hash" "index.btree"
    "phase4" "http.streaming"
    "phase5" "exec.row" "exec.vectorized" "exec.parallel"
    "join.hash" "join.merge" "join.nested_loop"
    "native.kernels"
    "change.union_all" "change.decimal38"))

(defparameter *max-default-threads* 16
  "Upper bound of the default worker threads per query (more rarely pays
off for the per-query thread start-up and merge costs).")

(defun default-query-threads ()
  "Worker threads per query without --threads: one per usable CPU, capped."
  (max 1 (min (cpu-count) *max-default-threads*)))

(defstruct engine-config
  (data-dir nil)                         ; pathname of the data directory (with trailing /)
  (test-functions nil)
  (max-query-memory-mb 2048)
  (max-ingest-bytes (* 4 1024 1024 1024))
  (max-table-rows 200000000)
  (max-join-rows 100000000)
  (threads (default-query-threads))
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

(defun plan-statement (session ast options)
  "Analyse and plan the query statement AST against a snapshot of the catalog
(concurrency.md §1) with the EXEC-OPTIONS OPTIONS. Returns (values plan
bound-query)."
  (let* ((catalog (catalog-snapshot (session-catalog session)))
         (bound (bind-statement ast catalog
                                :test-functions (engine-config-test-functions
                                                 (session-config session)))))
    (let ((*planning-catalog* catalog))
      (values (plan-bound-query bound options) bound))))

(defun result-columns (bound)
  (loop for c in (bound-query-columns bound)
        collect (make-column-def (column-def-name c) (output-type (column-def-type c)))))

(defun open-sql (session sql &key (options (make-exec-options)))
  "Parse, analyse and plan SQL in the current *QUERY-CONTEXT* with the
EXEC-OPTIONS OPTIONS. Index statements are executed immediately. Returns
(values columns iterator): the result COLUMN-DEFs and a function returning the
next result row or NIL."
  (let ((ast (parse-sql sql)))
    (flet ((no-rows () nil))
      (typecase ast
        (ast-create-index (execute-create-index session ast) (values '() #'no-rows))
        (ast-drop-index (execute-drop-index session ast) (values '() #'no-rows))
        (t
         (multiple-value-bind (plan bound) (plan-statement session ast options)
           (if (ast-explain-p ast)
               (let ((row (vector (json-to-string (explain-plan-json (physical-query-root plan))))))
                 (values (list (make-column-def "plan" :string))
                         (lambda () (shiftf row nil))))
               (values (result-columns bound)
                       (let ((*execution-settings* (physical-query-settings plan))
                             (*shared-results* (make-shared-results-table (physical-query-root plan))))
                         (funcall (the function (compile-plan (physical-query-root plan)))))))))))))

(defun execute-sql (session sql &key max-rows timeout-ms (collect-rows t)
                                     (options (make-exec-options)) context)
  "Run SQL against the session catalog and return a QUERY-RESULT. CONTEXT is
the QUERY-CONTEXT to run in (by default a fresh one with TIMEOUT-MS)."
  (let* ((*query-context* (or context (make-context-for session timeout-ms)))
         (memory-before (query-context-memory-used *query-context*)))
    (flet ((run (options)
             (with-query-cleanups (*query-context*)
               (multiple-value-bind (columns next) (open-sql session sql :options options)
                 (collect-rows columns next max-rows collect-rows)))))
      (if (eq (exec-options-mode options) :row)
          (run options)
          (handler-case (run options)
            (pq-error (e)
              (unless (data-error-p e)
                (error e))
              ;; A data error (overflow, division by zero, conversion, ...):
              ;; when rows fail differently, which error is met first depends
              ;; on the evaluation order. Re-running the statement on the row
              ;; executor reports exactly the row executor's outcome.
              (setf (query-context-memory-used *query-context*) memory-before)
              (run (row-mode-options options))))))))

(defun data-error-p (condition)
  (member (pq-error-code condition) *data-error-codes* :test #'string=))

(defun open-sql-with-row-fallback (session sql options)
  "OPEN-SQL for streamed results: when the vectorized executor fails with a
data error before producing the first row, the statement continues on the
row executor (as EXECUTE-SQL does); afterwards errors propagate."
  (let ((memory-before (query-context-memory-used *query-context*)))
    (flet ((row-open ()
             (let ((ctx *query-context*))
               (run-query-cleanups ctx)
               (setf (query-context-memory-used ctx) memory-before)
               (open-sql session sql :options (row-mode-options options)))))
      (if (eq (exec-options-mode options) :row)
          (open-sql session sql :options options)
          (multiple-value-bind (columns next)
              (handler-case (open-sql session sql :options options)
                (pq-error (e)
                  (if (data-error-p e) (row-open) (error e))))
            (let ((started nil))
              (values columns
                      (lambda ()
                        (if started
                            (funcall (the function next))
                            (handler-case (prog1 (funcall (the function next)) (setf started t))
                              (pq-error (e)
                                (unless (data-error-p e) (error e))
                                (setf started t
                                      next (nth-value 1 (row-open)))
                                (funcall (the function next)))))))))))))

(defun row-mode-options (options)
  "OPTIONS for the row executor (serial), otherwise unchanged."
  (let ((copy (copy-exec-options options)))
    (setf (exec-options-mode copy) :row
          (exec-options-threads copy) 1)
    copy))

(defun collect-rows (columns next max-rows collect-rows)
  "Drain the row iterator NEXT into a QUERY-RESULT (only counting rows unless
COLLECT-ROWS), enforcing MAX-ROWS and the memory budget."
  (declare (type function next))
  (let ((width (length columns))
        (rows '())
        (count 0))
    (declare (type fixnum count))
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

(defun explain-sql (session sql &key (options (make-exec-options)))
  "The EXPLAIN plan JSON of the query SQL (an EXPLAIN prefix is accepted)."
  (let ((*query-context* (make-context-for session nil))
        (ast (parse-sql sql)))
    (when (typep ast '(or ast-create-index ast-drop-index))
      (signal-pq-error "INVALID_REQUEST" "only queries can be explained"))
    (explain-plan-json (physical-query-root (plan-statement session ast options)))))

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

(defparameter *settle-heap-rows* 100000
  "Tables with more rows trigger a full garbage collection when published.")

(defun settle-heap (table)
  "After publishing a large TABLE, collect all generations once so its data
moves to the oldest generation. Otherwise the young-generation collections
that queries trigger keep promoting and rescanning the freshly loaded data,
which shows up as pauses of 100 ms and more in later queries."
  (when (> (table-row-count table) *settle-heap-rows*)
    (sb-ext:gc :full t))
  table)

(defun load-table (session spec source &key replace (layout :column) (dictionary :auto))
  "Create a table from SOURCE (octets for CSV, a string for JSON/JSONL) per the
INGEST-SPEC and publish it atomically. Returns the new table."
  (multiple-value-bind (defs data row-count)
      (ecase (ingest-spec-format spec)
        (:csv (ingest-csv source spec))
        ((:json :jsonl) (ingest-json source spec)))
    (settle-heap (catalog-add-table (session-catalog session)
                                    (make-table (ingest-spec-table-name spec) defs data row-count
                                                :layout layout :dictionary dictionary)
                                    :replace replace))))

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
        (load-pqcf-table native-path name :mmap mmap :layout layout
                         :max-rows (engine-config-max-table-rows (session-config session)))
      (let ((indexes (loop for (index-name column-name kind) in index-specs
                           collect (build-table-index index-name table
                                                      (find-column-index table column-name)
                                                      kind))))
        (settle-heap (catalog-add-table catalog table :replace replace :indexes indexes))))))
