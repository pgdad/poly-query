(ns pqledger.output-test
  (:require [clojure.test :refer [deftest is]]
            [pqledger.output :as out])
  (:import (java.time LocalDate LocalDateTime)))

(def result
  {:columns [{:name "month" :type "STRING"} {:name "income" :type "DECIMAL(18,2)"} {:name "n" :type "INT64"}]
   :rows [["2026-08" 100.00M 3] ["2026-09" -1200.00M 1]]})

(deftest table
  (is (= (str "month      income  n\n"
              "-------  --------  -\n"
              "2026-08    100.00  3\n"
              "2026-09  -1200.00  1\n"
              "(2 rows)\n")
         (out/format-table result)))
  (is (= "a  b\n-  -\n(0 rows)\n" (out/format-table {:columns [{:name "a" :type "STRING"} {:name "b" :type "INT64"}] :rows []})))
  (is (= "a\n--\nü✓\n(1 row)\n"
         (out/format-table {:columns [{:name "a" :type "STRING"}] :rows [["ü✓"]]})))
  (is (= "a\n-\n\n(1 row)\n" (out/format-table {:columns [{:name "a" :type "STRING"}] :rows [[nil]]})) "NULL is empty"))

(deftest csv
  (is (= "month,income,n\n2026-08,100.00,3\n2026-09,-1200.00,1\n" (out/format-csv result)))
  (is (= "s\n\"a,b\"\n\"say \"\"hi\"\"\"\n\"\"\n\n\" x\"\na\tb\n\"l\nm\"\n"
         (out/format-csv {:columns [{:name "s" :type "STRING"}]
                          :rows [["a,b"] ["say \"hi\""] [""] [nil] [" x"] ["a\tb"] ["l\nm"]]}))))

(deftest json
  (is (= "{\"month\":\"2026-08\",\"income\":\"100.00\",\"n\":3}\n{\"month\":\"2026-09\",\"income\":\"-1200.00\",\"n\":1}\n"
         (out/format-json result)))
  (is (= "" (out/format-json (assoc result :rows []))))
  (is (= "{\"s\":\"q\\\"b\\\\\\n\\t\\u0001é\",\"f\":1.500000,\"b\":true,\"x\":null}\n"
         (out/format-json {:columns [{:name "s" :type "STRING"} {:name "f" :type "FLOAT64"}
                                     {:name "b" :type "BOOLEAN"} {:name "x" :type "DATE"}]
                           :rows [["q\"b\\\n\t\u0001é" 1.5 true nil]]}))))

(deftest value-text
  (is (= "0.000000" (out/value-text "FLOAT64" -0.0)))
  (is (= "0.000000" (out/value-text "FLOAT64" -1.0E-9)))
  (is (= "2.500000" (out/value-text "FLOAT64" 2.5)))
  (is (= "0.333333" (out/value-text "FLOAT64" (/ 1.0 3))))
  (is (= "0.0" (out/value-text "DECIMAL(18,1)" 0.0M)))
  (is (= "0001-01-01" (out/value-text "DATE" (LocalDate/of 1 1 1))))
  (is (= "2026-01-02 03:04:05" (out/value-text "TIMESTAMP" (LocalDateTime/of 2026 1 2 3 4 5))))
  (is (= "2026-01-02 03:04:05.000007" (out/value-text "TIMESTAMP" (LocalDateTime/of 2026 1 2 3 4 5 7000))))
  (is (= "false" (out/value-text "BOOLEAN" false))))
