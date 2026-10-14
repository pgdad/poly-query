(ns pqledger.main
  "pqledger's entry point (spec/apps/pqledger.md): runs one command and
  maps its outcome to the exit status (§10)."
  (:require [pqledger.cli :as cli]
            [pqledger.config :as config]
            [pqledger.errors :as errors]
            [pqledger.importer :as importer]
            [pqledger.ledger :as ledger]
            [pqledger.output :as output]
            [pqledger.reports :as reports]
            [pqledger.rules :as rules]
            [polyquery.api :as pq])
  (:import (java.io PrintStream))
  (:gen-class))

(set! *warn-on-reflection* true)

(def version "1.0.0")

(defn- printed
  "A successful outcome printing a result in the selected format."
  ([result fmt] (printed result fmt 0))
  ([result fmt exit] {:exit exit :out (output/format-result result fmt)}))

(defn- line [s] {:exit 0 :out (str s "\n")})

(defn- with-ledger
  "Calls (f db) with an engine instance on the opened ledger and the rules
  loaded (the rules file is read first: configuration errors precede ledger
  state errors)."
  [config f]
  (let [rules (rules/read-rules config)]
    (with-open [db (ledger/create-engine config)]
      (ledger/open! db config)
      (ledger/load-rules! db rules)
      (f db))))

(defn- set-category!
  [config {:keys [id args opts]}]
  (with-ledger config
    (fn [db]
      (when (zero? (long (ledger/scalar db config (str "SELECT COUNT(*) FROM transactions WHERE id = " id))))
        (errors/ledger! (str "no transaction with id " (first args))))
      (let [others (pq/rows (ledger/query db config (str "SELECT id, category FROM overrides WHERE id <> "
                                                         id " ORDER BY id")))
            category (second args)]
        (ledger/write! db "overrides" (if (:clear opts)
                                        others
                                        (sort-by first (conj others [id category]))))
        (line (str "transaction " id ": "
                   (if (:clear opts) "category cleared" (str "category " category))))))))

(defn- run-query
  "`query SQL` (§9.5): engine errors of the statement itself ⇒ exit 5."
  [config sql fmt]
  (let [budgets (or (rules/read-budgets config) [])]
    (with-ledger config
      (fn [db]
        (ledger/load-budgets! db budgets)
        (ledger/materialize-ledger! db config)
        (let [result (try
                       (pq/query db sql (ledger/query-options config))
                       (catch clojure.lang.ExceptionInfo e
                         (if-let [code (pq/error-code e)]
                           (errors/fail! :query (str code ": " (ex-message e)))
                           (throw e))))]
          (printed {:columns (pq/columns result) :rows (pq/rows result)} fmt))))))

(defn- run-budget [config filters fmt]
  (let [budgets (or (rules/read-budgets config)
                    (errors/config! "budget requires budget_file in the [ledger] section"))]
    (with-ledger config
      (fn [db]
        (ledger/load-budgets! db budgets)
        (let [result (reports/budget db config filters)]
          (printed result fmt (if (reports/over-budget? result) 3 0)))))))

(defn- execute
  "Runs a parsed command line; returns {:exit n :out text}."
  [{:keys [global command opts args] :as parsed} env]
  (case command
    "help" {:exit 0 :out (cli/usage-text)}
    "version" (line (str "pqledger " version " (" (get (pq/version) "engine") " "
                         (get (pq/version) "engine_version") ")"))
    (let [config (config/load-config (config/locate (:config global) (get env "PQLEDGER_CONFIG")))
          fmt (or (:format global) (:format config))
          filters (select-keys opts [:month :from :to :account])]
      (case command
        "init" (do (ledger/init! config) (line "initialized ledger"))
        "import" (do (rules/read-rules config)
                     (line (importer/import! config (first args) (:account opts))))
        "report monthly" (with-ledger config #(printed (reports/monthly % config filters) fmt))
        "report categories" (with-ledger config #(printed (reports/categories % config filters) fmt))
        "report merchants" (with-ledger config
                             #(printed (reports/merchants % config filters (or (:top opts) 10)) fmt))
        "budget" (run-budget config filters fmt)
        "accounts" (with-ledger config #(printed (reports/accounts % config) fmt))
        "list" (with-ledger config
                 #(printed (reports/list-transactions % config filters
                                                      (if (:uncategorized opts) "uncategorized" (:category opts)))
                           fmt))
        "export" (with-ledger config #(printed (reports/export % config filters) fmt))
        "set-category" (set-category! config parsed)
        "query" (run-query config (first args) fmt)))))

(defn run
  "Runs pqledger with the command-line arguments and environment (a map);
  returns {:exit status :out stdout-text :err stderr-text}."
  [argv env]
  (try
    (execute (cli/parse argv) env)
    (catch Throwable e
      (let [message (if (errors/kind e)
                      (ex-message e)
                      (str "unexpected error: " (or (ex-message e) (.getName (class e)))))]
        {:exit (errors/exit-code e) :out "" :err (str "pqledger: error: " message "\n")}))))

(defn -main [& argv]
  ;; A thread with a large stack: deeply nested ad-hoc SQL must not
  ;; overflow it.
  (let [outcome (promise)
        t (Thread. nil #(deliver outcome (run (vec argv) (into {} (System/getenv)))) "pqledger" (* 256 1024 1024))]
    (.start t)
    (.join t)
    (let [{:keys [exit out err]} @outcome
          stdout (PrintStream. System/out false "UTF-8")
          stderr (PrintStream. System/err false "UTF-8")]
      (.print stdout ^String (or out ""))
      (.flush stdout)
      (when err (.print stderr ^String err) (.flush stderr))
      (System/exit (int exit)))))
