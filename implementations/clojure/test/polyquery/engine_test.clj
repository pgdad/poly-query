(ns polyquery.engine-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.catalog :as catalog]
            [polyquery.engine :as engine]
            [polyquery.ingest.csv :as csv]
            [polyquery.test-util :refer [error-code]])
  (:import (java.io StringReader)))

(def people-csv
  "id,name,age,score\n1,Alice,34,88.5\n2,Bob,28,\n3,Carol,,91.0\n4,dave,52,60.25\n")

(def cat0
  (catalog/add-table catalog/empty-catalog
                     (csv/load-csv (StringReader. people-csv)
                                   {:name "people" :header? true :delimiter \,
                                    :limits {:max-table-rows 100}})
                     false))

(defn- run
  ([sql] (run sql {}))
  ([sql opts] (engine/run-query cat0 sql opts)))

(defn- rows [sql] (mapv vec (:rows (run sql))))

(deftest projection-filter-order
  (is (= [["Alice" 35] ["dave" 53]] (rows "SELECT name, age + 1 AS a FROM people WHERE age > 30 ORDER BY a")))
  (is (= [[3] [2] [1] [4]] (rows "SELECT id FROM people ORDER BY age NULLS FIRST, id")))
  (is (= [[3] [1]] (rows "SELECT id FROM people ORDER BY score DESC LIMIT 2")))
  (is (= [[2] [3]] (rows "SELECT id FROM people ORDER BY id LIMIT 2 OFFSET 1")))
  (testing "ORDER BY an expression not in the select list"
    (is (= [["dave"] ["Alice"] ["Bob"] ["Carol"]] (rows "SELECT name FROM people ORDER BY -age NULLS LAST")))))

(deftest aggregates
  (is (= [[4 3 114 28 52 38.0]]
         (rows "SELECT COUNT(*), COUNT(age), SUM(age), MIN(age), MAX(age), AVG(age) FROM people")))
  (is (= [[0 nil]] (rows "SELECT COUNT(*), SUM(age) FROM people WHERE id > 10")))
  (is (= [["Alice" "dave"]] (rows "SELECT MIN(name), MAX(name) FROM people")))
  (is (= [[3]] (rows "SELECT COUNT(DISTINCT age > 30) + 1 FROM people"))))

(deftest expression-semantics
  (is (= [[3 -3 1 -1 "3.75" "3.125" 2.5]]
         (rows "SELECT 7 / 2, -7 / 2, 7 % 3, -7 % 3, 1.25 + 2.5, 1.25 * 2.5, 10.00 / 4")))
  (is (= [[false nil true nil]] (rows "SELECT NULL AND FALSE, NULL AND TRUE, NULL OR TRUE, NULL = NULL")))
  (is (= [["2024-03-01 00:00:00" "1.01" -3]]
         (rows "SELECT CAST(DATE '2024-03-01' AS TIMESTAMP), CAST('1.005' AS DECIMAL(4,2)), CAST(-3.75 AS INT64)"))))

(deftest runtime-errors
  (doseq [[sql code] [["SELECT 1 / 0" "DIVISION_BY_ZERO"]
                      ["SELECT 9223372036854775807 + 1" "NUMERIC_OVERFLOW"]
                      ["SELECT -9223372036854775808 / -1" "NUMERIC_OVERFLOW"]
                      ["SELECT 1e308 * 10" "NUMERIC_OVERFLOW"]
                      ["SELECT CAST('x' AS INT64)" "CONVERSION_ERROR"]
                      ["SELECT id FROM people LIMIT -1" "INVALID_ARGUMENT"]]]
    (testing sql (is (= code (error-code (run sql)))))))

(deftest limits
  (is (= "RESOURCE_LIMIT" (error-code (run "SELECT id FROM people" {:max-rows 3}))))
  (is (= 4 (:row-count (run "SELECT id FROM people" {:max-rows 4}))))
  (is (= "TIMEOUT" (error-code (engine/run-query cat0 "SELECT PQ_SLEEP(2000)"
                                                 {:timeout-ms 20 :test-functions? true})))))
