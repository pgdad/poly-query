(ns pqledger.statement-test
  (:require [clojure.test :refer [deftest is testing]]
            [pqledger.config :as config]
            [pqledger.statement :as st]
            [pqledger.test-util :refer [error-kind]])
  (:import (java.time LocalDate)))

(deftest csv-records
  (is (= [{:line 1 :fields ["a" "b"]} {:line 3 :fields ["x\ny" "q\""]} {:line 5 :fields ["1" ""]}]
         (st/parse-csv "a,b\n\n\"x\ny\",\"q\"\"\"\r\n1," \, 0 "f")))
  (testing "skip_lines counts physical lines"
    (is (= [{:line 3 :fields ["a" "b"]} {:line 4 :fields ["1" "2"]}]
           (st/parse-csv "pre;\"\npre\na;b\r\n1;2\r\n" \; 2 "f"))))
  (is (= [{:line 1 :fields ["a\"b" "c"]}] (st/parse-csv "a\"b\tc" \tab 0 "f")))
  (is (= :import (error-kind (st/parse-csv "a,\"b\n" \, 0 "f"))))
  (is (= :import (error-kind (st/parse-csv "a,\"b\"c\n" \, 0 "f")))))

(deftest dates
  (is (= (LocalDate/of 2026 1 5) (st/parse-date " 2026-01-05 " "YYYY-MM-DD")))
  (is (= (LocalDate/of 2026 1 5) (st/parse-date "20260105" "YYYYMMDD")))
  (is (= (LocalDate/of 2026 1 5) (st/parse-date "1/5/2026" "MM/DD/YYYY")))
  (is (= (LocalDate/of 2026 1 5) (st/parse-date "05/01/2026" "DD/MM/YYYY")))
  (is (= (LocalDate/of 2024 2 29) (st/parse-date "29.2.2024" "DD.MM.YYYY")))
  (doseq [[s fmt] [["2026-1-05" "YYYY-MM-DD"] ["2026-02-30" "YYYY-MM-DD"] ["2025-02-29" "YYYY-MM-DD"]
                   ["0000-01-01" "YYYY-MM-DD"] ["13/01/2026" "MM/DD/YYYY"] ["1/5/26" "MM/DD/YYYY"]
                   ["2026-01-05" "DD.MM.YYYY"] ["" "YYYYMMDD"]]]
    (is (nil? (st/parse-date s fmt)) s)))

(def us {:currency-symbol "$" :thousands-separator \, :decimal-separator \.})
(def de {:currency-symbol "€" :thousands-separator \. :decimal-separator \,})

(deftest amounts
  (is (= -103106 (st/parse-amount " ($1,031.06) " us)))
  (is (= -500 (st/parse-amount "-$5" us)))
  (is (= 500 (st/parse-amount "+5.00$" us)))
  (is (= 112000 (st/parse-amount "1.120,0 €" de)))
  (is (= 123456 (st/parse-amount "1 234,56" {:currency-symbol "" :thousands-separator \space :decimal-separator \,})))
  (is (= 0 (st/parse-amount "-0.00" us)))
  (is (= 999999999999999999 (st/parse-amount "9999999999999999.99" us)))
  (doseq [bad ["12.345" "$-5" "1e3" "" "." "5." "--5" "12345678901234567" "1,2.3.4"]]
    (is (string? (st/parse-amount bad us)) bad)))

(deftest merchants
  (is (= ["WHOLE FOODS MARKET" "SQ *BLUE BOTTLE" "RENT" "7-ELEVEN 12" "#123" "CAFé MéLANGE" "SHOP 12" "" "REI #"
          "A #1"]
         (map st/normalize-merchant ["Whole Foods Market #10234" "  SQ *Blue  Bottle 4421 " "Rent 2026"
                                     "7-Eleven 12" "#123" "Café\tMélange  #9" "Shop 12 345" "" "REI #"
                                     "a #1 #2"])))
  (testing "only spaces and tabs are trimmed (a line break of a quoted field stays)"
    (is (= "COFFEE\n" (st/normalize-merchant "Coffee\n")))
    (is (= "MULTI\r\nLINE" (st/normalize-merchant "Multi\r\nline")))))

(defn- settings [text]
  (config/import-settings (config/parse-config (str "[ledger]\ndata_dir = l\n" text) "c" (java.io.File. "."))
                          "a"))

(deftest transactions
  (testing "debit/credit with a preamble and positions"
    (is (= [{:line 4 :date (LocalDate/of 2026 1 1) :description "Miete" :merchant "MIETE" :cents -112000}
            {:line 5 :date (LocalDate/of 2026 1 2) :description "Gehalt" :merchant "GEHALT" :cents 381055}]
           (st/transactions "Konto\nZeitraum\nTag;Text;Soll;Haben\r\n01.01.2026; Miete ;1.120,00;\r\n2.1.2026;Gehalt;;3.810,55\r\n"
                            (settings (str "[import]\ndelimiter = ;\nskip_lines = 2\ndate_column = tag\ndate_format = DD.MM.YYYY\n"
                                           "description_column = 2\namount_mode = debit_credit\ndebit_column = soll\n"
                                           "credit_column = 4\ndecimal_separator = ,\nthousands_separator = .\n"))
                            "g.csv"))))
  (testing "invert_sign without a header"
    (is (= [-3106 3106]
           (map :cents (st/transactions "01/03/2026,Uber,$31.06\n01/05/2026,Uber,($31.06)\n"
                                        (settings (str "[import]\nheader = false\ndate_column = 1\ndescription_column = 2\n"
                                                       "amount_column = 3\ndate_format = MM/DD/YYYY\ncurrency_symbol = $\n"
                                                       "invert_sign = true\n"))
                                        "c.csv")))))
  (testing "errors name the file and the line"
    (doseq [[text msg] [["Date,Description,Amount\n2026-01-05,Lunch,-12.00\n2026-02-30,Dinner,-30.00\n" "f.csv:3:"]
                        ["Date,Description,Amount\n\n2026-01-05,Lunch,-12.005\n" "f.csv:3:"]
                        ["Date,Description,Amount\n2026-01-07,Extra,1.00,x\n" "f.csv:2:"]
                        ["Day,Description,Amount\n2026-01-05,Lunch,-12.00\n" "f.csv: "]
                        ["" "f.csv: "]]]
      (let [m (try (st/transactions text (settings "") "f.csv") nil
                   (catch clojure.lang.ExceptionInfo e (ex-message e)))]
        (is (and m (.startsWith ^String m msg)) [text m]))))
  (testing "both debit and credit empty"
    (is (= :import (error-kind (st/transactions "D,T,S,H\n2026-01-01,x,,\n"
                                                (settings "[import]\ndate_column=D\ndescription_column=T\namount_mode=debit_credit\ndebit_column=S\ncredit_column=H\n")
                                                "f.csv")))))
  (testing "a position beyond the record"
    (is (= :import (error-kind (st/transactions "2026-01-01,x\n"
                                                (settings "[import]\nheader=false\ndate_column=1\ndescription_column=2\namount_column=3\n")
                                                "f.csv"))))))
