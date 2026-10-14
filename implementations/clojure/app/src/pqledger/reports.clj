(ns pqledger.reports
  "Reports, listings and budgets (spec/apps/pqledger.md §8-§9). Each
  builds one SQL query that the embedded engine executes on the opened
  ledger; the results are returned as {:columns :rows} for printing. Only
  the `share` column of the categories report is computed here."
  (:require [clojure.string :as str]
            [pqledger.ledger :as ledger]
            [polyquery.api :as pq])
  (:import (java.math BigDecimal RoundingMode)
           (java.time LocalDate YearMonth)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Filters

(defn- date-literal ^String [^LocalDate d] (str "DATE '" d "'"))

(defn- month-start ^LocalDate [^YearMonth m] (.atDay m 1))
(defn- month-end ^LocalDate [^YearMonth m] (.atEndOfMonth m))

(defn filter-conditions
  "SQL conditions of the common filters {:month :from :to :account} (months
  as YearMonth) on a relation with columns \"date\" and account."
  [{:keys [month from to account]}]
  (let [from (or month from)
        to (or month to)]
    (cond-> []
      from (conj (str "\"date\" >= " (date-literal (month-start from))))
      to (conj (str "\"date\" <= " (date-literal (month-end to))))
      account (conj (str "account = " (ledger/sql-string account))))))

(defn- where ^String [conditions]
  (if (seq conditions) (str " WHERE " (str/join " AND " conditions)) ""))

(defn- result
  "A query result as {:columns :rows}."
  [r]
  {:columns (pq/columns r) :rows (pq/rows r)})

(defn- run [db config sql]
  (result (ledger/query db config sql)))

;; ---------------------------------------------------------------------------
;; Reports

(defn monthly
  [db config filters]
  (run db config
       (str "SELECT month, "
            "CAST(COALESCE(SUM(CASE WHEN amount > 0 THEN amount END), 0) AS DECIMAL(18,2)) AS income, "
            "CAST(COALESCE(-SUM(CASE WHEN amount < 0 THEN amount END), 0) AS DECIMAL(18,2)) AS expenses, "
            "CAST(SUM(amount) AS DECIMAL(18,2)) AS net, "
            "COUNT(*) AS transactions "
            "FROM (SELECT SUBSTR(CAST(\"date\" AS STRING), 1, 7) AS month, amount FROM transactions"
            (where (filter-conditions filters)) ") m "
            "GROUP BY month ORDER BY month")))

(defn share
  "100 × spent ÷ total, rounded half away from zero to one fractional digit
  (exact)."
  ^BigDecimal [^BigDecimal spent ^BigDecimal total]
  (.divide (.multiply spent (BigDecimal. 100)) total 1 RoundingMode/HALF_UP))

(defn categories
  [db config filters]
  (let [{:keys [rows]} (run db config
                            (ledger/with-ledger-view
                              (str "SELECT category, CAST(-SUM(amount) AS DECIMAL(18,2)) AS spent, "
                                   "COUNT(*) AS transactions FROM ledger"
                                   (where (conj (filter-conditions filters) "amount < 0"))
                                   " GROUP BY category ORDER BY spent DESC, category")))
        total (reduce #(.add ^BigDecimal %1 ^BigDecimal (second %2)) BigDecimal/ZERO rows)]
    {:columns [{:name "category" :type "STRING"} {:name "spent" :type "DECIMAL(18,2)"}
               {:name "share" :type "DECIMAL(18,1)"} {:name "transactions" :type "INT64"}]
     :rows (mapv (fn [[category spent n]] [category spent (share spent total) n]) rows)}))

(defn merchants
  [db config filters top]
  (run db config
       (str "SELECT merchant, CAST(-SUM(amount) AS DECIMAL(18,2)) AS spent, COUNT(*) AS transactions "
            "FROM transactions" (where (conj (filter-conditions filters) "amount < 0"))
            " GROUP BY merchant ORDER BY spent DESC, merchant LIMIT " (long top))))

(defn budget
  "The budget check of a month; budgets must be loaded as table `budgets`."
  [db config filters]
  (run db config
       (ledger/with-ledger-view
         (str ", spending AS (SELECT category, -SUM(amount) AS spent FROM ledger"
              (where (conj (filter-conditions filters) "amount < 0"))
              " GROUP BY category) "
              "SELECT b.category, b.amount AS budget, "
              "CAST(COALESCE(s.spent, 0) AS DECIMAL(18,2)) AS spent, "
              "CAST(b.amount - COALESCE(s.spent, 0) AS DECIMAL(18,2)) AS remaining, "
              "CASE WHEN COALESCE(s.spent, 0) <= b.amount THEN 'ok' ELSE 'over' END AS status "
              "FROM budgets b LEFT JOIN spending s ON s.category = b.category "
              "ORDER BY b.category"))))

(defn over-budget?
  [{:keys [rows]}]
  (boolean (some #(= "over" (peek %)) rows)))

(defn accounts
  [db config]
  (run db config
       (str "SELECT account, COUNT(*) AS transactions, CAST(SUM(amount) AS DECIMAL(18,2)) AS balance, "
            "MIN(\"date\") AS \"first\", MAX(\"date\") AS \"last\" "
            "FROM transactions GROUP BY account ORDER BY account")))

(defn list-transactions
  "`list`; category-filter: nil, or the resolved category to show."
  [db config filters category-filter]
  (run db config
       (ledger/with-ledger-view
         (str "SELECT id, \"date\", account, description, amount, category FROM ledger"
              (where (cond-> (filter-conditions filters)
                       category-filter (conj (str "category = " (ledger/sql-string category-filter)))))
              " ORDER BY \"date\", id"))))

(defn export
  [db config filters]
  (run db config
       (ledger/with-ledger-view
         (str "SELECT id, account, \"date\", description, merchant, amount, category, batch FROM ledger"
              (where (filter-conditions filters))
              " ORDER BY id"))))
