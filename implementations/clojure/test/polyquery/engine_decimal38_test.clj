(ns polyquery.engine-decimal38-test
  "End-to-end tests of CR-2 (spec/changes/decimal38.md): wide DECIMAL
  typing, arithmetic, exact comparisons, aggregates, joins and grouping give
  the same results under every execution option."
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.engine :as engine]
            [polyquery.catalog :as catalog]
            [polyquery.ingest.csv :as csv]
            [polyquery.storage.table :as table]
            [polyquery.test-util :refer [error-code]]
            [polyquery.types :as t])
  (:import (java.io StringReader)))

(def option-sets
  [{} {"mode" "row"} {"mode" "vectorized"} {"mode" "vectorized" "threads" 4}
   {"join" "merge"} {"join" "nested_loop"} {"optimize" false}])

(def t-csv
  (str "id,w,n\n"
       "1,12345678901234567890.1234567890,1.25\n"
       "2,-0.0000000001,2.50\n"
       "3,9999999999999999999999999999.9999999999,-3.75\n"
       "4,,\n"
       "5,12345678901234567890.1234567890,7\n"))

(defn- new-catalog
  "Table t with a wide (DECIMAL(38,10)) and a narrow (DECIMAL(10,2)) column."
  []
  (atom (catalog/add-table catalog/empty-catalog
                           (csv/load-csv (StringReader. t-csv)
                                         {:name "t" :header? true :delimiter \,
                                          :schema [(table/->Column "id" :int64)
                                                   (table/->Column "w" (t/decimal 38 10))
                                                   (table/->Column "n" (t/decimal 10 2))]
                                          :limits {:max-table-rows 1000}})
                           false)))

(def wide-view "t")

(defn- result
  "[column type names, serialized rows] of a query."
  [cat sql opts]
  (let [r (engine/execute! cat sql opts)]
    [(mapv #(get % "type") (:columns r)) (mapv vec (:rows r))]))

(defn- same-everywhere
  "The result of sql, asserting that every option set gives it."
  [cat sql]
  (let [results (mapv #(result cat sql %) option-sets)]
    (doseq [[o r] (map vector option-sets results)]
      (is (= (first results) r) (str sql " " o)))
    (first results)))

(deftest typing-and-arithmetic
  (let [cat (new-catalog)]
    (is (= [["DECIMAL(18,2)" "DECIMAL(38,2)"] [["3.75" "3.75"]]]
           (same-everywhere cat "SELECT 1.5 + 2.25, CAST(1.5 AS DECIMAL(19,1)) + 2.25")))
    (is (= [["DECIMAL(38,10)" "DECIMAL(38,12)"]
            [["12345678901234567891.3734567890" "15432098626543209862.654320986250"]
             ["2.4999999999" "-0.000000000250"]]]
           (same-everywhere cat (str "SELECT w + n, w * n FROM " wide-view " x WHERE id <= 2 ORDER BY id"))))
    (is (= "NUMERIC_OVERFLOW"
           (error-code (engine/execute! cat (str "SELECT w * n FROM " wide-view " x WHERE id = 3") {}))))
    (is (= "TYPE_ERROR"
           (error-code (engine/execute! cat "SELECT CAST(1 AS DECIMAL(38,20)) * CAST(1 AS DECIMAL(38,19))" {}))))))

(deftest exact-comparisons-joins-and-grouping
  (let [cat (new-catalog)]
    (is (= [["BOOLEAN"] [[true]]] (same-everywhere cat "SELECT 9223372036854775807 > 1.5")))
    (is (= [["INT64"] [[1] [3] [5]]]
           (same-everywhere cat (str "SELECT id FROM " wide-view " x WHERE w > n ORDER BY id"))))
    (is (= [["INT64" "INT64"] [[1 5]]]
           (same-everywhere cat (str "SELECT x.id, y.id FROM " wide-view " x JOIN " wide-view
                                     " y ON x.w = y.w AND x.id < y.id"))))
    (testing "a wide column joined with a narrow one compares exact values"
      (is (= [["INT64" "INT64"] [[1 2] [2 2] [3 2] [5 2]]]
             (same-everywhere cat (str "SELECT x.id, y.id FROM " wide-view " x JOIN " wide-view
                                       " y ON x.n * 0 - 0.0000000001 = y.w ORDER BY 1")))))
    (is (= [["DECIMAL(38,10)" "INT64" "DECIMAL(38,10)"]
            [[nil 1 nil]
             ["-0.0000000001" 1 "-0.0000000001"]
             ["12345678901234567890.1234567890" 2 "24691357802469135780.2469135780"]
             ["9999999999999999999999999999.9999999999" 1 "9999999999999999999999999999.9999999999"]]]
           (same-everywhere cat (str "SELECT w, COUNT(*), SUM(w) FROM " wide-view " x GROUP BY w ORDER BY w NULLS FIRST"))))
    (is (= "NUMERIC_OVERFLOW"
           (error-code (engine/execute! cat (str "SELECT SUM(w) + SUM(w) FROM " wide-view " x") {}))))))
