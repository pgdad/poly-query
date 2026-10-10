(ns polyquery.sql.analyzer-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.catalog :as catalog]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.storage.table :as table]
            [polyquery.test-util :refer [error-code]]
            [polyquery.types :as t]))

(def cat0
  (catalog/add-table catalog/empty-catalog
                     (table/make-table "people"
                                       [(table/->Column "id" :int64) (table/->Column "name" :string)
                                        (table/->Column "amount" (t/decimal 10 2))]
                                       [(object-array 0) (object-array 0) (object-array 0)] 0)
                     false))

(defn- analyze [sql]
  (:query (analyzer/analyze-statement cat0 (parser/parse-statement sql) {})))

(defn- out-types [sql] (mapv (comp t/type-name :type) (:outputs (analyze sql))))

(deftest literal-types
  (is (= ["INT64" "DECIMAL(3,2)" "DECIMAL(2,2)" "DECIMAL(1,1)" "FLOAT64" "STRING" "STRING"]
         (out-types "SELECT 1, 1.50, 0.05, .5, 1e3, 'x', NULL")))
  (is (= ["FLOAT64"] (out-types "SELECT 1234567890.1234567890"))))

(deftest arithmetic-types
  (is (= ["DECIMAL(18,2)" "DECIMAL(18,3)" "DECIMAL(18,1)" "FLOAT64" "INT64"]
         (out-types "SELECT 1.25 + 2.5, 1.25 * 2.5, 1.5 * 2, 10.00 / 4, 7 / 2")))
  (is (= ["DECIMAL(18,2)"] (out-types "SELECT amount + 1 FROM people")))
  (is (= ["DECIMAL(18,2)" "FLOAT64" "DECIMAL(10,2)"]
         (out-types "SELECT SUM(amount), AVG(amount), MAX(amount) FROM people"))))

(deftest output-names
  (is (= ["id" "_col2" "x" "name"]
         (mapv :name (:outputs (analyze "SELECT id, id + 1, name AS x, p.name FROM people p"))))))

(deftest validation-errors
  (doseq [[sql code] [["SELECT nope FROM people" "SEMANTIC_ERROR"]
                      ["SELECT * FROM nope" "SEMANTIC_ERROR"]
                      ["SELECT *" "SEMANTIC_ERROR"]
                      ["SELECT 1 = '1'" "TYPE_ERROR"]
                      ["SELECT 1.5 % 2" "TYPE_ERROR"]
                      ["SELECT id FROM people WHERE id" "TYPE_ERROR"]
                      ["SELECT id FROM people WHERE COUNT(*) > 1" "SEMANTIC_ERROR"]
                      ["SELECT SUM(COUNT(*)) FROM people" "SEMANTIC_ERROR"]
                      ["SELECT name, COUNT(*) FROM people" "SEMANTIC_ERROR"]
                      ["SELECT SUM(name) FROM people" "TYPE_ERROR"]
                      ["SELECT id FROM people ORDER BY 2" "SEMANTIC_ERROR"]
                      ["SELECT id FROM people LIMIT id" "SEMANTIC_ERROR"]
                      ["SELECT CAST(1 AS WIDGET)" "SEMANTIC_ERROR"]
                      ["SELECT CAST(1 AS DATE)" "TYPE_ERROR"]
                      ["SELECT 9223372036854775808" "NUMERIC_OVERFLOW"]
                      ["SELECT DATE '2023-02-29'" "CONVERSION_ERROR"]
                      ["SELECT 0.000000001 * 0.0000000001" "TYPE_ERROR"]
                      ["SELECT UPPER(id) FROM people" "TYPE_ERROR"]
                      ["SELECT FROBNICATE(1)" "SEMANTIC_ERROR"]
                      ["SELECT PQ_SLEEP(1)" "SEMANTIC_ERROR"]]]
    (testing sql (is (= code (error-code (analyze sql)))))))

(deftest order-by-resolution
  (let [q (analyze "SELECT id AS k, name FROM people ORDER BY k DESC, 2, amount")]
    (is (= [{:output 0} {:output 1}] (mapv #(select-keys % [:output]) (take 2 (:order-by q)))))
    (is (= :column (:node (:expr (nth (:order-by q) 2)))))
    (is (= [false true true] (mapv :nulls-first? (:order-by q))))))
