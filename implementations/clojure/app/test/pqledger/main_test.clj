(ns pqledger.main-test
  "End-to-end runs of commands (pqledger.main/run) in a temporary directory."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is]]
            [pqledger.main :as main]
            [pqledger.test-util :refer [temp-dir write-file!]]))

(deftest a-session
  (let [dir (temp-dir)
        conf (.getPath (write-file! dir "pqledger.conf"
                                    "[ledger]\ndata_dir = books\nrules_file = rules.conf\nbudget_file = budgets.conf\n"))
        _ (write-file! dir "rules.conf" "coffee = STARBUCKS*\n")
        _ (write-file! dir "budgets.conf" "coffee = 5\n")
        csv (.getPath (write-file! dir "s.csv" "Date,Description,Amount\n2026-03-02,Starbucks 12,-4.50\n2026-03-03,Starbucks 12,-4.50\n"))
        run (fn [& args] (main/run (into ["--config" conf] args) {}))]
    (is (= {:exit 0 :out "initialized ledger\n"} (run "init")))
    (is (= 6 (:exit (run "init"))))
    (is (= "batch 1: imported 2, duplicates 0\n" (:out (run "import" csv "--account" "a"))))
    (is (= "batch 2: imported 0, duplicates 2\n" (:out (run "import" csv "--account" "a"))))
    (is (= "category,budget,spent,remaining,status\ncoffee,5.00,9.00,-4.00,over\n"
           (:out (run "--format" "csv" "budget" "--month" "2026-03"))))
    (is (= 3 (:exit (run "budget" "--month" "2026-03"))))
    (is (= "transaction 2: category treats\n" (:out (run "set-category" "2" "treats"))))
    (is (= 6 (:exit (run "set-category" "3" "treats"))))
    (is (= "{\"category\":\"coffee\",\"n\":1}\n{\"category\":\"treats\",\"n\":1}\n"
           (:out (run "--format" "json" "query" "SELECT category, COUNT(*) AS n FROM ledger GROUP BY category ORDER BY category"))))
    (let [{:keys [exit out err]} (run "query" "SELEC 1")]
      (is (= [5 ""] [exit out]))
      (is (str/starts-with? err "pqledger: error: PARSE_ERROR: ")))
    (is (= 2 (:exit (main/run ["--config" (str conf ".missing") "accounts"] {}))))
    (is (= 1 (:exit (run "bogus"))))
    (is (= 0 (:exit (main/run ["help"] {}))))
    (is (str/starts-with? (:out (main/run ["version"] {})) "pqledger "))))
