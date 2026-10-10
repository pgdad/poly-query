(ns polyquery.engine-phase5-test
  "Phase 5 differential tests: every query must give the same result (or
  the same error) under every combination of execution mode, join
  algorithm, thread count and optimizer setting (spec/phases/phase-5.md).
  The tables are generated pseudo-randomly with NULLs in every column and
  are larger than a batch and a parallel partition."
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [polyquery.catalog :as catalog]
            [polyquery.engine :as engine]
            [polyquery.ingest.csv :as csv]
            [polyquery.storage.table :as table]
            [polyquery.types :as t])
  (:import (java.io StringReader)
           (java.util Random)))

(defn- gen-csv
  "CSV text of n rows from (row-fn rnd i) → vector of field strings."
  [header n row-fn]
  (let [rnd (Random. 42)]
    (str (str/join "," header) "\n"
         (str/join (for [i (range n)] (str (str/join "," (row-fn rnd i)) "\n"))))))

(defn- maybe [^Random rnd pct x] (if (< (.nextInt rnd 100) pct) "" x))

(def t-csv
  (gen-csv ["id" "g" "k" "d" "f" "s" "u" "b" "dt" "ts"] 3000
           (fn [^Random rnd i]
             [(inc i)
              (maybe rnd 5 (.nextInt rnd 10))
              (maybe rnd 5 (.nextInt rnd 500))
              (maybe rnd 8 (format "%.2f" (- (* 2000.0 (.nextDouble rnd)) 1000.0)))
              (maybe rnd 8 (format "%.3f" (* 100.0 (.nextGaussian rnd))))
              (maybe rnd 10 (["red" "green" "blue" "Yellow" "black" "w h i t e"] (.nextInt rnd 6)))
              (maybe rnd 3 (str "u" (.nextInt rnd 2000)))
              (maybe rnd 10 (if (.nextBoolean rnd) "true" "false"))
              (maybe rnd 5 (format "2024-%02d-%02d" (inc (.nextInt rnd 12)) (inc (.nextInt rnd 28))))
              (maybe rnd 5 (format "2023-%02d-%02d %02d:%02d:%02d" (inc (.nextInt rnd 12))
                                   (inc (.nextInt rnd 28)) (.nextInt rnd 24) (.nextInt rnd 60)
                                   (.nextInt rnd 60)))])))

(def r-csv
  (gen-csv ["k" "name" "w"] 800
           (fn [^Random rnd i]
             [(maybe rnd 5 (.nextInt rnd 600))
              (maybe rnd 5 (str "n" (mod i 37)))
              (maybe rnd 5 (format "%.1f" (* 10.0 (.nextDouble rnd))))])))

(def t-schema
  [["id" :int64] ["g" :int64] ["k" :int64] ["d" (t/decimal 10 2)] ["f" :float64]
   ["s" :string] ["u" :string] ["b" :boolean] ["dt" :date] ["ts" :timestamp]])

(def r-schema [["k" :int64] ["name" :string] ["w" (t/decimal 6 1)]])

(defn- load-table [cat tname text schema storage]
  (catalog/add-table cat
                     (csv/load-csv (StringReader. text)
                                   {:name tname :header? true :delimiter \,
                                    :schema (mapv (fn [[n ty]] (table/->Column n ty)) schema)
                                    :limits {:max-table-rows 100000}
                                    :storage storage})
                     false))

(def the-catalog
  (delay (atom (-> catalog/empty-catalog
                   (load-table "t" t-csv t-schema {})
                   (load-table "trow" t-csv t-schema {:layout :row})
                   (load-table "r" r-csv r-schema {})))))

(def configs
  [{:mode "row" :join "nested_loop" :threads 1 :optimize false}
   {:mode "row" :join "hash" :threads 1}
   {:mode "row" :join "merge" :threads 4}
   {:mode "vectorized" :join "hash" :threads 4}
   {:mode "vectorized" :join "merge" :threads 1 :optimize false}
   {:mode "vectorized" :join "nested_loop" :threads 4}
   {:mode "auto" :threads 3}])

(def reference {:mode "row" :join "hash" :threads 1 :optimize false})

(def queries
  ;; [sql ordered?]
  [["SELECT * FROM t" false]
   ["SELECT * FROM trow WHERE g = 3 OR s IS NULL" false]
   ["SELECT id, d * 2 + 1, f / 3, k % 7, -d, -f FROM t WHERE d > 10.5 AND f < 50" false]
   ["SELECT id FROM t WHERE NOT (b AND g > 4) OR d BETWEEN -5 AND 5" false]
   ["SELECT id, g IN (1, 2, NULL), s IN ('red', 'blue'), s NOT IN ('red', NULL) FROM t" false]
   ["SELECT id, s LIKE 'b%', u LIKE '%1_', s NOT LIKE '%e%' FROM t" false]
   ["SELECT id, CASE WHEN g > 5 THEN 'hi' WHEN g > 2 THEN s ELSE NULL END, COALESCE(s, u, 'none'), NULLIF(g, 3) FROM t" false]
   ["SELECT id, CAST(k AS FLOAT64), CAST(d AS INT64), CAST(dt AS TIMESTAMP), CAST(g AS STRING) || s FROM trow" false]
   ["SELECT id, UPPER(s), LENGTH(u), SUBSTR(u, 2, 2), YEAR(dt), MONTH(ts), ROUND(d, 1), ABS(f) FROM t" false]
   ["SELECT id FROM t WHERE ts > TIMESTAMP '2023-06-01 00:00:00' AND dt < DATE '2024-07-01'" false]
   ["SELECT id FROM t WHERE dt >= ts" false]
   ["SELECT id FROM t WHERE d = 0 OR f = 0 OR b = false OR s = 'red' OR s < 'c' OR g <> 2" false]
   ["SELECT g, COUNT(*), COUNT(k), SUM(k), SUM(d), AVG(d), AVG(f), MIN(s), MAX(ts), MIN(f), MAX(dt) FROM t GROUP BY g" false]
   ["SELECT s, b, COUNT(*), SUM(f), COUNT(DISTINCT g), SUM(DISTINCT k) FROM trow GROUP BY s, b" false]
   ["SELECT k % 10, COUNT(*), MAX(d) FROM t WHERE g IS NOT NULL GROUP BY k % 10 HAVING COUNT(*) > 100" false]
   ["SELECT COUNT(*), SUM(d), AVG(k), MIN(u), MAX(f) FROM t WHERE id < 0" false]
   ["SELECT COUNT(*), SUM(d), AVG(k), MIN(u), MAX(f), COUNT(DISTINCT s) FROM t" false]
   ["SELECT u, COUNT(*) FROM t GROUP BY u" false]
   ["SELECT dt, SUM(g) FROM t GROUP BY dt" false]
   ["SELECT t.id, r.name, r.w FROM t JOIN r ON r.k = t.k" false]
   ["SELECT t.id, r.name FROM t LEFT JOIN r ON r.k = t.k AND r.w > 5" false]
   ["SELECT t.id, r.name FROM t JOIN r ON r.k = t.k AND r.name = t.u" false]
   ["SELECT t.id, r.k FROM t JOIN r ON r.k = t.g * 10 AND t.d > r.w" false]
   ["SELECT t.g, COUNT(*), SUM(r.w) FROM t, r WHERE t.k = r.k AND t.s = 'red' GROUP BY t.g" false]
   ["SELECT t.id, r.k FROM t JOIN r ON t.k < r.k - 595" false]
   ["SELECT t.id, x.k FROM t LEFT JOIN (SELECT k, COUNT(*) AS c FROM r GROUP BY k) x ON x.k = t.k WHERE t.g = 1" false]
   ["SELECT a.id, b.id FROM t a JOIN t b ON a.u = b.u AND a.id < b.id WHERE a.g = 1" false]
   ["SELECT id, d FROM t ORDER BY d DESC, id" true]
   ["SELECT id, s, f FROM t ORDER BY s NULLS FIRST, f DESC NULLS LAST, id" true]
   ["SELECT id, k FROM t ORDER BY k, id LIMIT 25 OFFSET 10" true]
   ["SELECT id, ts FROM trow ORDER BY ts DESC NULLS LAST, id LIMIT 7" true]
   ["SELECT id, u FROM t ORDER BY u DESC, id DESC LIMIT 40" true]
   ["SELECT id FROM t ORDER BY id LIMIT 0" true]
   ["SELECT g, SUM(d) AS sd FROM t GROUP BY g ORDER BY sd DESC NULLS FIRST" true]
   ["SELECT DISTINCT g, s FROM t" false]
   ["SELECT COUNT(*) FROM (SELECT DISTINCT u FROM t WHERE b) x" false]
   ["SELECT id FROM t WHERE k IN (SELECT k FROM r WHERE w > 9)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k AND r.w < 1)" false]
   ["SELECT id, (SELECT MAX(w) FROM r WHERE r.k = t.k) FROM t WHERE g = 2" false]
   ["SELECT id FROM t WHERE d > (SELECT AVG(d) FROM t) AND g = 0" false]
   ["WITH c AS (SELECT g, COUNT(*) AS n FROM t GROUP BY g) SELECT t.id, c.n FROM t JOIN c ON c.g = t.g WHERE t.k < 20" false]
   ["SELECT id FROM t WHERE g <> 0 AND k / g > 100" false]
   ["SELECT id, CASE WHEN g = 0 THEN NULL ELSE k / g END FROM t" false]
   ["SELECT id FROM t LIMIT 5" false]
   ;; runtime errors
   ["SELECT id, k / g FROM t" false]
   ["SELECT SUM(k * 4611686018427387) FROM t" false]
   ["SELECT id, CAST(u AS INT64) FROM t" false]
   ["SELECT (SELECT k FROM r) FROM t" false]])

(defn- normalize-value [x]
  (if (double? x) (format "%.6g" (double x)) (pr-str x)))

(defn- run [cat sql opts]
  (try
    (let [r (engine/execute! cat sql opts)]
      {:columns (:columns r) :rows (mapv #(mapv normalize-value %) (:rows r))})
    (catch clojure.lang.ExceptionInfo e
      {:error (:pq/code (ex-data e))})))

(defn- comparable [result ordered?]
  (if (or ordered? (:error result)) result (update result :rows #(sort-by pr-str %))))

(deftest option-matrix-gives-identical-results
  (let [cat @the-catalog]
    (doseq [[sql ordered?] queries]
      (let [expected (comparable (run cat sql reference) ordered?)]
        (testing sql
          (is (or (:error expected) (seq (:columns expected))))
          (doseq [c configs]
            (testing (pr-str c)
              (is (= expected (comparable (run cat sql c) ordered?))))))))))

(deftest error-queries-fail
  (let [cat @the-catalog]
    (is (= "DIVISION_BY_ZERO" (:error (run cat "SELECT id, k / g FROM t" {:mode "vectorized" :threads 4}))))
    (is (= "NUMERIC_OVERFLOW" (:error (run cat "SELECT SUM(k * 4611686018427387) FROM t" {:mode "vectorized" :threads 4}))))
    (is (= "SUBQUERY_CARDINALITY" (:error (run cat "SELECT (SELECT k FROM r) FROM t" {}))))))

(deftest explain-shows-phase5-operators
  (let [cat @the-catalog
        ops (fn [sql opts] (set (map #(get % "op") (tree-seq map? #(get % "children")
                                                             (engine/explain-plan @cat sql opts)))))]
    (is (contains? (ops "SELECT * FROM t JOIN r ON r.k = t.k" {:join "merge"}) "MergeJoin"))
    (is (contains? (ops "SELECT * FROM t JOIN r ON r.k = t.k" {:join "hash"}) "HashJoin"))
    (is (contains? (ops "SELECT * FROM t JOIN r ON r.k = t.k" {:join "nested_loop"}) "NestedLoopJoin"))
    (is (contains? (ops "SELECT id FROM t ORDER BY d LIMIT 3" {}) "TopN"))
    (is (not (contains? (ops "SELECT id FROM t ORDER BY d LIMIT 3" {:optimize false}) "TopN")))
    (is (contains? (ops "SELECT id FROM t WHERE g = 1" {:threads 4}) "Gather"))
    (is (not (contains? (ops "SELECT id FROM t WHERE g = 1" {:threads 1}) "Gather")))))
