;;;; reports.lisp — the SQL behind reports, budgets, accounts, list and export
;;;; (pqledger.md §8, §9). All filtering, aggregation and ordering happens in
;;;; the embedded engine; the host only adds the `share` column.

(in-package #:pqledger)

(defstruct filters
  "The common filter options: MONTH, FROM and TO are (YEAR . MONTH) conses."
  month from to account)

(defun filter-conditions (filters)
  "SQL conditions (strings) selecting the transactions that pass FILTERS."
  (let ((conditions '()))
    (flet ((add (format-control &rest args)
             (push (apply #'format nil format-control args) conditions)))
      (let ((month (filters-month filters))
            (from (filters-from filters))
            (to (filters-to filters)))
        (when month
          (add "\"date\" BETWEEN DATE '~A' AND DATE '~A'"
               (month-first-day month) (month-last-day month)))
        (when from (add "\"date\" >= DATE '~A'" (month-first-day from)))
        (when to (add "\"date\" <= DATE '~A'" (month-last-day to))))
      (when (filters-account filters)
        (add "account = ~A" (sql-string (filters-account filters)))))
    (nreverse conditions)))

(defun where-clause (conditions)
  (if conditions (format nil "WHERE ~{~A~^ AND ~}" conditions) ""))

(defun ledger-report (ledger sql)
  (report-from-result (ledger-query ledger sql)))

;;; ------------------------------------------------------------------
;;; Reports

(defun monthly-report (ledger filters)
  (ledger-report ledger (format nil "SELECT SUBSTR(CAST(\"date\" AS STRING), 1, 7) AS month,
       CAST(SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END) AS DECIMAL(18,2)) AS income,
       CAST(-SUM(CASE WHEN amount < 0 THEN amount ELSE 0 END) AS DECIMAL(18,2)) AS expenses,
       CAST(SUM(amount) AS DECIMAL(18,2)) AS net,
       COUNT(*) AS transactions
FROM transactions ~A
GROUP BY SUBSTR(CAST(\"date\" AS STRING), 1, 7)
ORDER BY month" (where-clause (filter-conditions filters)))))

(defun share-tenths (spent total)
  "100 × SPENT ÷ TOTAL in tenths of a percent, rounded half away from zero
(SPENT and TOTAL are exact non-negative rationals, TOTAL > 0)."
  (floor (+ (* 2000 spent) total) (* 2 total)))

(defun categories-report (ledger filters)
  (let* ((rows (query-rows ledger (categorized-sql
                                   (format nil "SELECT category, CAST(-SUM(amount) AS DECIMAL(18,2)) AS spent,
       COUNT(*) AS transactions
FROM ledger ~A
GROUP BY category
ORDER BY spent DESC, category"
                                           (where-clause (cons "amount < 0" (filter-conditions filters)))))))
         (total (loop for row across rows sum (svref row 1))))
    (make-report '("category" "spent" "share" "transactions")
                 '("STRING" "DECIMAL(18,2)" "DECIMAL(18,1)" "INT64")
                 (map 'vector (lambda (row)
                                (vector (svref row 0) (svref row 1)
                                        (/ (share-tenths (svref row 1) total) 10)
                                        (svref row 2)))
                      rows))))

(defun merchants-report (ledger filters top)
  (ledger-report ledger (format nil "SELECT merchant, CAST(-SUM(amount) AS DECIMAL(18,2)) AS spent,
       COUNT(*) AS transactions
FROM transactions ~A
GROUP BY merchant
ORDER BY spent DESC, merchant
LIMIT ~D" (where-clause (cons "amount < 0" (filter-conditions filters)))
                                (min top *max-id*))))

(defun budget-report (ledger filters)
  "The budget report of the month in FILTERS and whether a category is over budget."
  (let ((report
          (ledger-report ledger (categorized-sql
                                 "SELECT b.category AS category, b.amount AS budget,
       CAST(COALESCE(s.spent, 0) AS DECIMAL(18,2)) AS spent,
       CAST(b.amount - COALESCE(s.spent, 0) AS DECIMAL(18,2)) AS remaining,
       CASE WHEN COALESCE(s.spent, 0) <= b.amount THEN 'ok' ELSE 'over' END AS status
FROM budgets b LEFT JOIN spent_by_category s ON s.category = b.category
ORDER BY category"
                                 (format nil "spent_by_category AS (
  SELECT category, -SUM(amount) AS spent FROM ledger ~A GROUP BY category)"
                                         (where-clause (cons "amount < 0" (filter-conditions filters))))))))
    (values report
            (some (lambda (row) (string= (svref row 4) "over")) (report-rows report)))))

(defun accounts-report (ledger)
  (ledger-report ledger "SELECT account, COUNT(*) AS transactions,
       CAST(SUM(amount) AS DECIMAL(18,2)) AS balance,
       MIN(\"date\") AS \"first\", MAX(\"date\") AS \"last\"
FROM transactions
GROUP BY account
ORDER BY account"))

(defun list-report (ledger filters category)
  "The transactions passing FILTERS (and with the resolved CATEGORY, if given)."
  (ledger-report ledger (categorized-sql
                         (format nil "SELECT id, \"date\", account, description, amount, category
FROM ledger ~A
ORDER BY \"date\", id"
                                 (where-clause (append (filter-conditions filters)
                                                       (and category
                                                            (list (format nil "category = ~A"
                                                                          (sql-string category))))))))))

(defun export-report (ledger filters)
  (ledger-report ledger (categorized-sql
                         (format nil "SELECT id, account, \"date\", description, merchant, amount,
       category, batch
FROM ledger ~A
ORDER BY id" (where-clause (filter-conditions filters))))))

(defun query-report (ledger sql budgets)
  "Run the user's SQL with the tables of §9.5 loaded; engine errors exit 5."
  (install-budgets ledger budgets)
  (materialize-ledger-table ledger)
  (report-from-result (with-engine-failures ('query-error)
                        (pq:query (ledger-database ledger) sql))))
