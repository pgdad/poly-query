(ns pqledger.config-test
  (:require [clojure.test :refer [deftest is testing]]
            [pqledger.config :as config]
            [pqledger.test-util :refer [error-kind]])
  (:import (java.io File)))

(def dir (File. "/base"))

(defn- parse [text] (config/parse-config text "test.conf" dir))

(deftest minimal-and-defaults
  (let [c (parse "[ledger]\ndata_dir = books\n")]
    (is (= (File. dir "books") (:data-dir c)))
    (is (nil? (:rules-file c)))
    (is (= "table" (:format c)))
    (is (= config/import-defaults (config/import-settings c "any")))))

(deftest syntax
  (testing "BOM, CRLF, comments, indentation and quoted values"
    (let [c (parse "﻿; comment\r\n# another\r\n  [ledger]  \r\n data_dir = \" my \\\"books\\\" \\\\ \"\r\n")]
      (is (= (File. dir " my \"books\" \\ ") (:data-dir c)))))
  (testing "an empty quoted value"
    (is (= "" (:currency-symbol (config/import-settings (parse "[ledger]\ndata_dir=x\n[import]\ncurrency_symbol = \"\"\n") "a"))))))

(deftest sections-and-overrides
  (let [c (parse (str "[ledger]\ndata_dir = l\nrules_file = /abs/rules.conf\n"
                      "[import]\ndelimiter = tab\nheader = false\ndate_column = 1\ndescription_column = 2\namount_column = 3\n"
                      "[account visa]\ndate_format = MM/DD/YYYY\ninvert_sign = true\nthousands_separator = space\n"
                      "[output]\nformat = json\n[engine]\nthreads = 4\nmemory_mb = 512\n"))
        visa (config/import-settings c "visa")
        other (config/import-settings c "other")]
    (is (= (File. "/abs/rules.conf") (:rules-file c)))
    (is (= "json" (:format c)))
    (is (= [4 512] [(:threads c) (:memory-mb c)]))
    (is (= [\tab false 1 "MM/DD/YYYY" true \space]
           ((juxt :delimiter :header :date-column :date-format :invert-sign :thousands-separator) visa)))
    (is (= ["YYYY-MM-DD" false] ((juxt :date-format :invert-sign) other)))))

(deftest errors
  (doseq [text ["data_dir = l\n[ledger]\n"
                "[ledger]\ndata_dir = l\ncolour = blue\n"
                "[ledger]\ndata_dir = l\ndata_dir = m\n"
                "[ledger]\nrules_file = r\n"
                "[import]\nheader = true\n"
                "[ledger]\ndata_dir = l\n[ledger]\n"
                "[ledger]\ndata_dir = l\n[accounts]\n"
                "[ledger]\ndata_dir = l\n[account Bad]\n"
                "[ledger]\ndata_dir = l\n[account a]\n[account a]\n"
                "[ledger]\ndata_dir = l\n[output]\nformat = xml\n"
                "[ledger]\ndata_dir = l\n[import]\nheader = yes\n"
                "[ledger]\ndata_dir = l\n[import]\ndelimiter = ab\n"
                "[ledger]\ndata_dir = l\n[import]\nskip_lines = -1\n"
                "[ledger]\ndata_dir = l\n[import]\ndate_format = YY-MM-DD\n"
                "[ledger]\ndata_dir = l\n[import]\ndate_column = 0\n"
                "[ledger]\ndata_dir = l\n[engine]\nthreads = 0\n"
                "[ledger]\ndata_dir = l\nthis is not an assignment\n"
                "[ledger]\ndata_dir = l\n[account eu]\ndecimal_separator = ,\nthousands_separator = ,\n"
                "[ledger]\ndata_dir = l\n[import]\nthousands_separator = ,\n[account eu]\ndecimal_separator = ,\n"
                "[ledger]\ndata_dir = l\n[import]\nheader = false\n"]]
    (is (= :config (error-kind (parse text))) text)))

(deftest error-messages-name-the-line
  (is (re-find #"test\.conf:3" (try (parse "[ledger]\ndata_dir = l\ncolour = blue\n")
                                    (catch Exception e (ex-message e))))))

(deftest locate
  (is (= "a.conf" (.getName (config/locate "a.conf" "env.conf"))))
  (is (= "env.conf" (.getName (config/locate nil "env.conf"))))
  (is (= "pqledger.conf" (.getName (config/locate nil ""))))
  (is (= "pqledger.conf" (.getName (config/locate nil nil)))))

(deftest names
  (is (config/account-name? "my-acct_1"))
  (is (not (config/account-name? "Bad Name")))
  (is (not (config/account-name? (apply str (repeat 33 "a")))))
  (is (config/category-name? "groceries"))
  (is (not (config/category-name? "uncategorized")))
  (is (not (config/category-name? "Groceries"))))
