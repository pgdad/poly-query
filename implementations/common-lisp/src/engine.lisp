;;;; engine.lisp — the engine facade: configuration, sessions, SQL execution
;;;; pipeline (lex -> parse -> bind -> plan -> execute) and table loading.

(in-package #:polyquery)

(defparameter *engine-version* "0.1.0")
(defparameter *spec-version* "1.0.0")
(defparameter *protocol-version* 1)

(defparameter *capabilities*
  '("phase1" "ingest.csv" "ingest.json" "ingest.jsonl" "sql.basic" "test.functions"))

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

(defun execute-sql (session sql &key max-rows timeout-ms (collect-rows t))
  "Run SQL against the session catalog and return a QUERY-RESULT."
  (let* ((config (session-config session))
         (*query-context* (make-query-context
                           :deadline (make-deadline timeout-ms)
                           :memory-budget (* (engine-config-max-query-memory-mb config) 1024 1024)))
         (ast (parse-sql sql))
         (bound (bind-statement ast (session-catalog session)
                                :test-functions (engine-config-test-functions config)))
         (plan (plan-select bound))
         (next (build-iterator (planned-query-root plan)))
         (width (length (planned-query-columns plan)))
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
    (make-query-result :columns (planned-query-columns plan)
                       :rows (nreverse rows)
                       :row-count count)))

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
