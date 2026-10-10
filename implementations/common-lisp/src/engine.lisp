;;;; engine.lisp — the engine facade: configuration, sessions, SQL execution
;;;; pipeline (lex -> parse -> bind -> plan -> execute) and table loading.

(in-package #:polyquery)

(defparameter *engine-version* "0.1.0")
(defparameter *spec-version* "1.0.0")
(defparameter *protocol-version* 1)

(defparameter *capabilities*
  '("phase1" "ingest.csv" "ingest.json" "ingest.jsonl" "sql.basic" "test.functions"
    "phase2" "sql.groupby" "sql.join" "sql.functions" "sql.subquery" "sql.cte"
    "sql.correlated_subquery"))

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

(defun prepare-statement (session sql)
  "Lex, parse, analyse and plan SQL. Returns (values physical-plan bound-query ast)."
  (let* ((ast (parse-sql sql))
         (bound (bind-statement ast (session-catalog session)
                                :test-functions (engine-config-test-functions
                                                 (session-config session)))))
    (values (plan-bound-query bound) bound ast)))

(defun result-columns (bound)
  (loop for c in (bound-query-columns bound)
        collect (make-column-def (column-def-name c) (output-type (column-def-type c)))))

(defun execute-sql (session sql &key max-rows timeout-ms (collect-rows t))
  "Run SQL against the session catalog and return a QUERY-RESULT."
  (let ((*query-context* (make-context-for session timeout-ms)))
    (multiple-value-bind (plan bound ast) (prepare-statement session sql)
      (if (ast-explain-p ast)
          (make-query-result :columns (list (make-column-def "plan" :string))
                             :rows (list (vector (json-to-string (explain-plan-json plan))))
                             :row-count 1)
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
                               :row-count count))))))

(defun explain-sql (session sql)
  "The EXPLAIN plan JSON of the query SQL (an EXPLAIN prefix is accepted)."
  (let ((*query-context* (make-context-for session nil)))
    (explain-plan-json (prepare-statement session sql))))

;;; ------------------------------------------------------------------
;;; Loading

(defun load-table (session spec source &key replace)
  "Create a table from SOURCE (octets for CSV, a string for JSON/JSONL) per the
INGEST-SPEC and publish it atomically. Returns the new table."
  (multiple-value-bind (defs data row-count)
      (ecase (ingest-spec-format spec)
        (:csv (ingest-csv source spec))
        ((:json :jsonl) (ingest-json source spec)))
    (catalog-add-table (session-catalog session)
                       (make-table (ingest-spec-table-name spec) defs data row-count)
                       :replace replace)))
