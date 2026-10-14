(ns pqledger.cli-test
  (:require [clojure.test :refer [deftest is]]
            [pqledger.cli :as cli]
            [pqledger.test-util :refer [error-kind]])
  (:import (java.time YearMonth)))

(deftest parsing
  (is (= {:global {:config "c.conf" :format "csv"} :command "report monthly"
          :opts {:month (YearMonth/of 2026 9) :account "visa"} :args []}
         (cli/parse ["--config" "c.conf" "--format" "csv" "report" "monthly" "--account" "visa" "--month" "2026-09"])))
  (is (= ["f.csv"] (:args (cli/parse ["import" "--account" "a" "f.csv"]))))
  (is (= {:id 12 :args ["12" "food"]} (select-keys (cli/parse ["set-category" "12" "food"]) [:id :args])))
  (is (:clear (:opts (cli/parse ["set-category" "--clear" "12"]))))
  (is (= "help" (:command (cli/parse ["--help"]))))
  (is (= 3 (:top (:opts (cli/parse ["report" "merchants" "--top" "3"])))))
  (is (= "SELECT 1" (first (:args (cli/parse ["query" "SELECT 1"]))))))

(deftest usage-errors
  (doseq [argv [[] ["frobnicate"] ["report"] ["report" "weekly"] ["--format" "xml" "accounts"]
                ["--bogus" "accounts"] ["accounts" "extra"] ["accounts" "--month" "2026-01"]
                ["report" "monthly" "--month" "2026-01" "--from" "2026-01"]
                ["report" "monthly" "--month" "2026-13"] ["report" "monthly" "--month" "0000-01"]
                ["report" "monthly" "--month" "2026-1"] ["report" "monthly" "--month"]
                ["report" "monthly" "--from" "2026-03" "--to" "2026-02"]
                ["report" "monthly" "--month" "2026-01" "--month" "2026-02"]
                ["import" "t.csv"] ["import" "--account" "a"] ["import" "t.csv" "--account" "Bad Name"]
                ["set-category" "1" "Groceries"] ["set-category" "1" "uncategorized"] ["set-category" "1"]
                ["set-category" "0" "x"] ["set-category" "x" "y"] ["set-category" "1" "x" "--clear"]
                ["report" "merchants" "--top" "0"] ["report" "merchants" "--top" "x"]
                ["list" "--category" "a" "--uncategorized"] ["budget"] ["query"] ["query" "a" "b"]
                ["--config" "a" "--config" "b" "accounts"] ["version" "x"] ["help" "x"]]]
    (is (= :usage (error-kind (cli/parse argv))) (pr-str argv))))
