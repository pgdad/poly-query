;;;; ledger.lisp — the ledger (pqledger.md §4) on the embedded engine: the
;;;; three PQCF tables, opening and storing them, category resolution in SQL,
;;;; importing statements and editing overrides.
;;;;
;;;; Every access goes through the embedding API: the ledger files are opened
;;;; as engine tables, queried with SQL and written back with SAVE-TABLE.

(in-package #:pqledger)

(defparameter *ledger-schema*
  '(("transactions" ("id" "INT64") ("account" "STRING") ("date" "DATE") ("description" "STRING")
                    ("merchant" "STRING") ("amount" "DECIMAL(18,2)") ("batch" "INT64"))
    ("batches" ("batch" "INT64") ("account" "STRING") ("file" "STRING") ("imported" "INT64")
               ("duplicates" "INT64"))
    ("overrides" ("id" "INT64") ("category" "STRING")))
  "The tables of the ledger and their columns, in order (§4).")

(defun table-columns (table)
  (cdr (assoc table *ledger-schema* :test #'string=)))

(defun table-file (table)
  (concatenate 'string table ".pqcf"))

(defstruct (ledger (:constructor %make-ledger (config database)))
  "An open ledger: the CONFIG it belongs to and the engine DATABASE holding
its tables."
  config database)

;;; ------------------------------------------------------------------
;;; Engine access

(defmacro with-engine-failures ((&optional (failure ''fatal-error)) &body body)
  "Run BODY; an engine error becomes a pqledger error signalled by FAILURE."
  `(handler-case (progn ,@body)
     (pq:engine-error (e)
       (funcall ,failure "~A: ~A" (pq:engine-error-code e) (pq:engine-error-message e)))))

(defun make-ledger-database (config)
  (with-engine-failures ()
    (pq:make-database :data-dir (config-data-dir config)
                      :threads (and (config-threads config) (min (config-threads config) 256))
                      :max-query-memory-mb (config-memory-mb config))))

(defun ledger-query (ledger sql)
  "Run SQL on LEDGER's database; engine errors are fatal (exit 7)."
  (with-engine-failures ()
    (pq:query (ledger-database ledger) sql)))

(defun query-rows (ledger sql)
  "The row vectors of SQL's result."
  (pq:result-rows (ledger-query ledger sql)))

(defun query-scalar (ledger sql)
  "The single value SQL returns."
  (svref (svref (query-rows ledger sql) 0) 0))

(defun replace-table (ledger table columns rows)
  "Create (or replace) TABLE with COLUMNS and ROWS in LEDGER's database."
  (with-engine-failures ()
    (pq:create-table (ledger-database ledger) table columns rows :replace t)))

(defun ledger-exists-p (config)
  (file-exists-p (concatenate 'string (config-data-dir config) (table-file "transactions"))))

(defun check-table-schema (ledger table)
  "Signal a fatal error unless TABLE has the columns of §4."
  (let ((actual (mapcar (lambda (c) (list (pq:column-name c) (pq:column-type c)))
                        (with-engine-failures () (pq:table-schema (ledger-database ledger) table))))
        (expected (table-columns table)))
    (unless (and (= (length actual) (length expected))
                 (every (lambda (a e) (and (ascii-string-equal (first a) (first e))
                                           (string= (second a) (second e))))
                        actual expected))
      (fatal-error "~A~A does not have the columns of a ledger table"
                   (config-data-dir (ledger-config ledger)) (table-file table)))))

(defun call-with-ledger (config function)
  "Call FUNCTION with the open LEDGER of CONFIG; its database is closed afterwards.
A missing ledger is a ledger state error."
  (unless (ledger-exists-p config)
    (ledger-error "no ledger in ~A (run `pqledger init` first)" (config-data-dir config)))
  (let ((ledger (%make-ledger config (make-ledger-database config))))
    (unwind-protect
         (progn
           (dolist (entry *ledger-schema*)
             (let ((table (first entry)))
               (with-engine-failures ()
                 (pq:open-table (ledger-database ledger) table (table-file table)))
               (check-table-schema ledger table)))
           (funcall function ledger))
      (pq:close-database (ledger-database ledger)))))

(defmacro with-ledger ((ledger config) &body body)
  `(call-with-ledger ,config (lambda (,ledger) ,@body)))

(defun store-tables (ledger tables)
  "Write the TABLES of LEDGER's database to their ledger files. Each table is
first saved to a temporary file; only when all are written are they renamed
into place, so a failure leaves the ledger unchanged."
  (let* ((dir (config-data-dir (ledger-config ledger)))
         (staged (mapcar (lambda (table) (cons table (format nil ".pqledger-~A.tmp" table))) tables)))
    (handler-case
        (progn
          (loop for (table . temp) in staged
                do (with-engine-failures ()
                     (pq:save-table (ledger-database ledger) table temp)))
          (loop for (table . temp) in staged
                do (sb-posix:rename (concatenate 'string dir temp)
                                    (concatenate 'string dir (table-file table)))))
      (sb-posix:syscall-error (e)
        (fatal-error "cannot write the ledger in ~A: ~A" dir e)))
    (loop for (nil . temp) in staged
          do (ignore-errors (delete-file (sb-ext:parse-native-namestring
                                          (concatenate 'string dir temp)))))))

;;; ------------------------------------------------------------------
;;; Rules, budgets and the categorized ledger

(defun install-rules (ledger rules)
  "Create the table `rules` (rule_no, category, pattern) from RULES."
  (replace-table ledger "rules" '(("rule_no" "INT64") ("category" "STRING") ("pattern" "STRING"))
                 (mapcar (lambda (r) (list (rule-number r) (rule-category r) (rule-pattern r)))
                         rules)))

(defun install-budgets (ledger budgets)
  "Create the table `budgets` (category, amount) from the alist BUDGETS."
  (replace-table ledger "budgets" '(("category" "STRING") ("amount" "DECIMAL(18,2)"))
                 (mapcar (lambda (b) (list (car b) (/ (cdr b) 100))) budgets)))

(defparameter *categorized-ctes*
  "rule_patterns AS (
  SELECT rule_no, category, REPLACE(REPLACE(pattern, '*', '%'), '?', '_') AS like_pattern
  FROM rules),
merchant_rules AS (
  SELECT m.merchant AS merchant, MIN(p.rule_no) AS rule_no
  FROM (SELECT DISTINCT merchant FROM transactions) m
  JOIN rule_patterns p ON m.merchant LIKE p.like_pattern
  GROUP BY m.merchant),
merchant_categories AS (
  SELECT mr.merchant AS merchant, r.category AS category
  FROM merchant_rules mr JOIN rules r ON r.rule_no = mr.rule_no),
ledger AS (
  SELECT t.id AS id, t.account AS account, t.\"date\" AS \"date\", t.description AS description,
         t.merchant AS merchant, t.amount AS amount, t.batch AS batch,
         COALESCE(o.category, mc.category, 'uncategorized') AS category
  FROM transactions t
  LEFT JOIN overrides o ON o.id = t.id
  LEFT JOIN merchant_categories mc ON mc.merchant = t.merchant)"
  "Common table expressions defining `ledger`: the transactions with their
resolved category (§5.1). A rule pattern becomes a LIKE pattern (`*` → `%`,
`?` → `_`; patterns contain neither `%` nor `_`); merchants and patterns are
both upper-cased in ASCII, so LIKE's case-sensitive match is the specified
ASCII case-insensitive one. The first matching rule (lowest rule_no) wins,
an override beats every rule.")

(defun categorized-sql (select &rest more-ctes)
  "The SQL statement SELECT (which may refer to `ledger`) preceded by the
category resolution CTEs and MORE-CTES (strings `name AS (query)`)."
  (format nil "WITH ~A~{,~%~A~}~%~A" *categorized-ctes* more-ctes select))

(defun materialize-ledger-table (ledger)
  "Create the table `ledger`: the transactions columns and `category`."
  (let ((result (ledger-query ledger (categorized-sql
                                      "SELECT id, account, \"date\", description, merchant, amount,
       batch, category FROM ledger ORDER BY id"))))
    (replace-table ledger "ledger"
                   (append (table-columns "transactions") '(("category" "STRING")))
                   (pq:result-rows result))))

;;; ------------------------------------------------------------------
;;; init

(defun init-ledger (config)
  "Create the data directory and the three empty tables (§6.1)."
  (when (ledger-exists-p config)
    (ledger-error "a ledger already exists in ~A" (config-data-dir config)))
  (handler-case (ensure-directories-exist (sb-ext:parse-native-namestring (config-data-dir config)))
    (error (e) (fatal-error "cannot create ~A: ~A" (config-data-dir config) e)))
  (let ((ledger (%make-ledger config (make-ledger-database config))))
    (unwind-protect
         (progn
           (loop for (table . columns) in *ledger-schema*
                 do (replace-table ledger table columns '()))
           ;; transactions.pqcf marks an existing ledger, so it is renamed last
           (store-tables ledger '("batches" "overrides" "transactions")))
      (pq:close-database (ledger-database ledger)))))

;;; ------------------------------------------------------------------
;;; import

(defun cents-of (amount)
  "The cents of a DECIMAL(18,2) value (a rational)."
  (round (* amount 100)))

(defun existing-key-counts (ledger account)
  "A hash table (date cents merchant) -> number of ACCOUNT's transactions."
  (let ((counts (make-hash-table :test 'equal)))
    (loop for row across (query-rows ledger (format nil "SELECT \"date\", amount, merchant, COUNT(*)
FROM transactions WHERE account = ~A GROUP BY \"date\", amount, merchant" (sql-string account)))
          do (setf (gethash (list (svref row 0) (cents-of (svref row 1)) (svref row 2)) counts)
                   (svref row 3)))
    counts))

(defun select-new-entries (entries existing)
  "The ENTRYs to import (§6.4): of the F file records with one key, of which
L are already in the ledger (EXISTING), the last max(0, F - L). Returns them
in file order and the number of duplicates."
  (let ((seen (make-hash-table :test 'equal))
        (fresh '())
        (duplicates 0))
    ;; The k-th record of a key (in file order) is new iff k > L.
    (dolist (entry entries)
      (let ((key (list (entry-date entry) (entry-cents entry) (entry-merchant entry))))
        (if (> (incf (gethash key seen 0)) (gethash key existing 0))
            (push entry fresh)
            (incf duplicates))))
    (values (nreverse fresh) duplicates)))

(defun max-or-zero (value)
  (if (pq:null-value-p value) 0 value))

(defun import-entries (ledger account file entries)
  "Add the new ENTRYs of the statement FILE (a base name) for ACCOUNT as a new
batch. Returns the batch number, the number imported and the duplicates."
  (multiple-value-bind (fresh duplicates)
      (select-new-entries entries (existing-key-counts ledger account))
    (let* ((next-id (1+ (max-or-zero (query-scalar ledger "SELECT MAX(id) FROM transactions"))))
           (batch (1+ (max-or-zero (query-scalar ledger "SELECT MAX(batch) FROM batches"))))
           (tables '("batches")))
      (when fresh
        (replace-table
         ledger "transactions" (table-columns "transactions")
         (concatenate 'vector
                      (query-rows ledger "SELECT id, account, \"date\", description, merchant,
       amount, batch FROM transactions ORDER BY id")
                      (loop for entry in fresh
                            for id from next-id
                            collect (vector id account (entry-date entry) (entry-description entry)
                                            (entry-merchant entry) (/ (entry-cents entry) 100) batch))))
        (push "transactions" tables))
      (replace-table ledger "batches" (table-columns "batches")
                     (concatenate 'vector
                                  (query-rows ledger "SELECT batch, account, file, imported, duplicates
FROM batches ORDER BY batch")
                                  (list (vector batch account file (length fresh) duplicates))))
      (store-tables ledger tables)
      (values batch (length fresh) duplicates))))

;;; ------------------------------------------------------------------
;;; set-category

(defparameter *max-id* (1- (expt 2 63)))

(defun set-override (ledger id category)
  "Set (CATEGORY a string) or remove (CATEGORY NIL) the override of transaction ID."
  (when (or (> id *max-id*)
            (zerop (query-scalar ledger (format nil "SELECT COUNT(*) FROM transactions WHERE id = ~D" id))))
    (ledger-error "unknown transaction ~D" id))
  (replace-table ledger "new_override" (table-columns "overrides")
                 (if category (list (list id category)) '()))
  (replace-table ledger "overrides" (table-columns "overrides")
                 (query-rows ledger (format nil "SELECT id, category FROM overrides WHERE id <> ~D
UNION ALL SELECT id, category FROM new_override ORDER BY id" id)))
  (store-tables ledger '("overrides")))
