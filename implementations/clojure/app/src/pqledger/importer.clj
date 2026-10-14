(ns pqledger.importer
  "`pqledger import` (spec/apps/pqledger.md §6.2, §6.4): converts a
  statement file and appends its new transactions to the ledger, skipping
  the records already present."
  (:require [pqledger.config :as config]
            [pqledger.errors :as errors]
            [pqledger.ledger :as ledger]
            [pqledger.statement :as statement]
            [pqledger.text :as text]
            [polyquery.api :as pq])
  (:import (java.io File)
           (java.math BigDecimal)
           (java.nio.file Files)))

(set! *warn-on-reflection* true)

(defn- read-statement
  "The text of the statement file (import data errors for a missing,
  unreadable or non-UTF-8 file)."
  ^String [^File f ^String shown]
  (let [bs (try
             (when-not (.isFile f) (throw (java.io.IOException. "no such file")))
             (Files/readAllBytes (.toPath f))
             (catch java.io.IOException e
               (errors/fail! :import (str shown ": cannot read the file (" (.getMessage e) ")"))))]
    (or (text/decode-utf8 bs)
        (errors/fail! :import (str shown ": the file is not valid UTF-8")))))

(defn- cents ^long [^BigDecimal amount]
  (.longValueExact (.unscaledValue (.setScale amount 2))))

(defn- dedup-key [date ^long cents merchant] [date cents merchant])

(defn- ledger-counts
  "{[date cents merchant] n}: the account's transactions per duplicate key."
  [db config account]
  (into {}
        (map (fn [[date amount merchant n]] [(dedup-key date (cents amount) merchant) n]))
        (pq/rows (ledger/query db config
                               (str "SELECT \"date\", amount, merchant, COUNT(*) FROM transactions "
                                    "WHERE account = " (ledger/sql-string account) " "
                                    "GROUP BY \"date\", amount, merchant")))))

(defn select-new
  "The records to import (§6.4): per key with f records in the file and l in
  the ledger, the last max(0, f − l) records in file order."
  [records ledger-count]
  (let [keyf #(dedup-key (:date %) (:cents %) (:merchant %))
        in-file (frequencies (map keyf records))]
    (first
     (reduce (fn [[out seen] r]
               (let [k (keyf r)
                     i (long (get seen k 0))
                     skip (min (long (in-file k)) (long (ledger-count k 0)))]
                 [(if (>= i skip) (conj out r) out) (assoc seen k (inc i))]))
             [[] {}]
             records))))

(defn import!
  "Imports file-arg (a path relative to the current directory) into the
  account's ledger. Returns the summary line."
  [config ^String file-arg account]
  (with-open [db (ledger/create-engine config)]
    (ledger/open! db config)
    (let [f (.getAbsoluteFile (File. file-arg))
          records (statement/transactions (read-statement f file-arg)
                                          (config/import-settings config account)
                                          file-arg)
          fresh (select-new records (ledger-counts db config account))
          next-id (inc (long (or (ledger/scalar db config "SELECT MAX(id) FROM transactions") 0)))
          batch (inc (max (long (or (ledger/scalar db config "SELECT MAX(batch) FROM batches") 0))
                          (long (or (ledger/scalar db config "SELECT MAX(batch) FROM transactions") 0))))
          new-rows (map-indexed (fn [i {:keys [date description merchant cents]}]
                                  [(+ next-id i) account date description merchant
                                   (BigDecimal/valueOf (long cents) 2) batch])
                                fresh)
          imported (count fresh)
          duplicates (- (count records) imported)
          existing #(pq/rows (ledger/query db config (str "SELECT * FROM " % " ORDER BY " %2)))]
      (ledger/write! db "transactions" (concat (existing "transactions" "id") new-rows))
      (ledger/write! db "batches" (conj (existing "batches" "batch")
                                        [batch account (.getName f) imported duplicates]))
      (str "batch " batch ": imported " imported ", duplicates " duplicates))))
