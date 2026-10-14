(ns pqledger.ledger
  "The ledger (spec/apps/pqledger.md §4): its PQCF tables in the data
  directory, read and written through the embedding API, plus the SQL
  that resolves transaction categories (§5.1)."
  (:require [clojure.string :as str]
            [pqledger.errors :as errors]
            [polyquery.api :as pq])
  (:import (java.io File)))

(set! *warn-on-reflection* true)

(def tables
  "The ledger's tables and their columns (§4), in storage order."
  {"transactions" [["id" "INT64"] ["account" "STRING"] ["date" "DATE"] ["description" "STRING"]
                   ["merchant" "STRING"] ["amount" "DECIMAL(18,2)"] ["batch" "INT64"]]
   "batches" [["batch" "INT64"] ["account" "STRING"] ["file" "STRING"] ["imported" "INT64"]
              ["duplicates" "INT64"]]
   "overrides" [["id" "INT64"] ["category" "STRING"]]})

(defn file-name ^String [table] (str table ".pqcf"))

(defn sql-string
  "A SQL string literal."
  ^String [^String s]
  (str "'" (str/replace s "'" "''") "'"))

(defn engine-error!
  "Rethrows an engine error met while reading or writing the ledger as an
  'other' error (exit 7)."
  [e]
  (if (pq/error-code e)
    (errors/fail! :other (str (pq/error-code e) ": " (ex-message e)))
    (throw e)))

(defmacro with-engine-errors
  "Evaluates body; engine errors become exit-7 errors."
  [& body]
  `(try ~@body
        (catch clojure.lang.ExceptionInfo e# (engine-error! e#))))

;; ---------------------------------------------------------------------------
;; Instances

(defn exists?
  [{:keys [^File data-dir]}]
  (.isFile (File. data-dir (file-name "transactions"))))

(defn create-engine
  "An engine instance on the ledger's data directory, with the [engine]
  settings."
  ^java.io.Closeable [{:keys [^File data-dir threads memory-mb]}]
  (pq/create (cond-> {:data-dir data-dir}
               threads (assoc :threads threads)
               memory-mb (assoc :max-query-memory-mb memory-mb))))

(defn query-options
  "Query options of the [engine] settings."
  [{:keys [threads]}]
  (cond-> {} threads (assoc :threads threads)))

(defn query
  "Runs SQL on the ledger instance; engine errors ⇒ exit 7."
  ([db config sql]
   (with-engine-errors (pq/query db sql (query-options config)))))

(defn scalar
  "The single value of a one-row, one-column query."
  [db config sql]
  (ffirst (pq/rows (query db config sql))))

(defn- check-columns!
  [db table]
  (let [want (get tables table)
        got (mapv (juxt :name :type) (:columns (pq/schema db table)))]
    (when-not (= want got)
      (errors/fail! :other (str (file-name table) " does not have the ledger's columns "
                                (str/join ", " (map #(str/join " " %) want)))))))

(defn open!
  "Opens the ledger's tables in db (a missing batches or overrides file is
  read as an empty table). Requires an existing ledger (else exit 6)."
  [db config]
  (when-not (exists? config)
    (errors/ledger! (str "no ledger in " (.getPath ^File (:data-dir config))
                         " (run 'pqledger init' first)")))
  (with-engine-errors
    (doseq [[table columns] tables]
      (if (.isFile (File. ^File (:data-dir config) (file-name table)))
        (do (pq/open! db table (file-name table))
            (check-columns! db table))
        (pq/load-rows! db table columns [])))))

(defn write!
  "Replaces a ledger table with rows (in the table's column order) and saves
  it to its PQCF file."
  [db table rows]
  (with-engine-errors
    (pq/load-rows! db table (get tables table) rows {:replace true})
    (pq/save! db table (file-name table))))

(defn init!
  "Creates the data directory and an empty ledger (§6.1)."
  [{:keys [^File data-dir] :as config}]
  (when (exists? config)
    (errors/ledger! (str "a ledger already exists in " (.getPath data-dir))))
  (.mkdirs data-dir)
  (when-not (.isDirectory data-dir)
    (errors/fail! :other (str "cannot create the data directory " (.getPath data-dir))))
  (with-open [db (create-engine config)]
    ;; transactions.pqcf last: it marks the ledger as existing
    (doseq [table ["batches" "overrides" "transactions"]]
      (write! db table []))))

;; ---------------------------------------------------------------------------
;; Rules, budgets and categories

(defn load-rules!
  "Loads the rules as table `rules` (rule_no, category, pattern)."
  [db rules]
  (with-engine-errors
    (pq/load-rows! db "rules" [["rule_no" "INT64"] ["category" "STRING"] ["pattern" "STRING"]]
                   (map (juxt :rule-no :category :pattern) rules))))

(defn load-budgets!
  "Loads the budgets as table `budgets` (category, amount)."
  [db budgets]
  (with-engine-errors
    (pq/load-rows! db "budgets" [["category" "STRING"] ["amount" "DECIMAL(18,2)"]]
                   (map (juxt :category :amount) budgets))))

(def ^:private ledger-ctes
  ;; Rule patterns become LIKE patterns (* → %, ? → _; patterns contain
  ;; neither % nor _). Patterns are upper-cased, so UPPER on the merchant
  ;; makes the match ASCII case-insensitive. Each distinct merchant is
  ;; matched once; its category is that of the first matching rule.
  (str "WITH merchants AS (SELECT DISTINCT merchant FROM transactions), "
       "matches AS (SELECT m.merchant, MIN(r.rule_no) AS rule_no FROM merchants m JOIN rules r "
       "ON UPPER(m.merchant) LIKE REPLACE(REPLACE(r.pattern, '*', '%'), '?', '_') "
       "GROUP BY m.merchant), "
       "resolved AS (SELECT x.merchant, r.category FROM matches x JOIN rules r ON r.rule_no = x.rule_no), "
       "ledger AS (SELECT t.id, t.account, t.\"date\", t.description, t.merchant, t.amount, t.batch, "
       "COALESCE(o.category, c.category, 'uncategorized') AS category "
       "FROM transactions t LEFT JOIN overrides o ON o.id = t.id "
       "LEFT JOIN resolved c ON c.merchant = t.merchant)"))

(defn with-ledger-view
  "SQL text: `select` (which may read `ledger`, the transactions with their
  resolved category) preceded by the CTEs defining `ledger`. Requires the
  rules table."
  ^String [^String select]
  (str ledger-ctes " " select))

(defn materialize-ledger!
  "Loads the resolved view as table `ledger` (for ad-hoc queries, §9.5)."
  [db config]
  (let [result (query db config (with-ledger-view
                                  (str "SELECT id, account, \"date\", description, merchant, amount, "
                                       "batch, category FROM ledger ORDER BY id")))]
    (with-engine-errors
      (pq/load-rows! db "ledger" (conj (get tables "transactions") ["category" "STRING"])
                     (pq/rows result)))))
