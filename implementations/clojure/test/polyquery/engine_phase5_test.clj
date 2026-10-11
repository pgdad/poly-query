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
            [polyquery.protocol :as protocol]
            [polyquery.storage.table :as table]
            [polyquery.types :as t])
  (:import (java.io StringReader)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)
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

(def s-csv
  (gen-csv ["k" "name" "w"] 60
           (fn [^Random rnd i]
             [(maybe rnd 5 (.nextInt rnd 40))
              (maybe rnd 5 (str "n" (mod i 7)))
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

(defn- with-pqcf-copy
  "Adds table `tp`: t saved as PQCF with row groups of 700 rows (so that
  row-group skipping and parallel ranges cross segments) and memory-mapped."
  [cat]
  (let [dir (.toFile (Files/createTempDirectory "pq-p5" (make-array FileAttribute 0)))
        st (protocol/make-state {:data-dir dir :limits {:max-table-rows 100000 :max-query-memory-mb 512}})
        req #(protocol/handle-request st %)]
    (reset! (:catalog st) cat)
    (assert (get (req {"op" "save" "table" "t" "path" "t.pqcf" "options" {"row_group_size" 700}}) "ok"))
    (assert (get (req {"op" "open" "table" "tp" "path" "t.pqcf" "options" {"mmap" true}}) "ok"))
    @(:catalog st)))

(def the-catalog
  (delay (atom (-> catalog/empty-catalog
                   (load-table "t" t-csv t-schema {})
                   (load-table "trow" t-csv t-schema {:layout :row})
                   (load-table "r" r-csv r-schema {})
                   (load-table "s" s-csv r-schema {})
                   (load-table "small" (str/join "\n" (take 151 (str/split-lines t-csv))) t-schema {})
                   with-pqcf-copy))))

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
   ["SELECT * FROM tp WHERE id > 650 AND id < 2200 AND g <> 4" false]
   ["SELECT g, COUNT(*), SUM(d), MIN(s), MAX(f) FROM tp WHERE id BETWEEN 1000 AND 2900 GROUP BY g" false]
   ["SELECT tp.id, r.name FROM tp JOIN r ON r.k = tp.k WHERE tp.id >= 1400" false]
   ["SELECT id, ts FROM tp WHERE dt IS NOT NULL ORDER BY ts, id LIMIT 30" true]
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
   ;; join reordering, constant folding, predicate simplification
   ["SELECT a.id, b.k, s.name FROM small a, s, small b WHERE a.k % 40 = s.k AND b.id = a.id + 1 AND s.w > 8" false]
   ["SELECT COUNT(*), SUM(small.d) FROM s x, s y, small WHERE small.k % 40 = x.k AND small.g = y.k" false]
   ["SELECT x.k, y.k, z.w FROM s x, s y, s z WHERE x.k = z.k AND z.w > 5 AND y.name = x.name" false]
   ["SELECT a.id, s.name, b.u FROM small a JOIN small b ON b.id = a.id LEFT JOIN s ON s.k = a.g WHERE a.g = 2" false]
   ["SELECT COUNT(*) FROM s x CROSS JOIN s y WHERE x.w > 9" false]
   ["SELECT small.id, x.n FROM small, (SELECT k, name AS n FROM s) x, s WHERE x.k = small.g AND s.k = small.g AND s.name = x.n" false]
   ["SELECT id, 1 + 2 * 3, CASE WHEN 1 = 1 THEN 'a' END, ABS(-4.5) FROM t WHERE 2 > 1 AND (g = 1 OR 1 = 0)" false]
   ["SELECT id FROM t WHERE TRUE AND NOT NOT (g = 3) AND (g = 3 OR FALSE) AND g = 3" false]
   ["SELECT id FROM t WHERE k / 0 = 1 AND FALSE" false]
   ;; UNION ALL (spec/changes/union-all.md)
   ["SELECT id, d FROM t WHERE g = 1 UNION ALL SELECT k, w FROM r" false]
   ["SELECT g, COUNT(*), SUM(d) FROM t GROUP BY g UNION ALL SELECT k, COUNT(*), SUM(w) FROM r GROUP BY k" false]
   ["SELECT s FROM t UNION ALL SELECT name FROM r UNION ALL SELECT NULL ORDER BY 1 DESC NULLS LAST" true]
   ["SELECT id, f FROM t UNION ALL SELECT k, w FROM r ORDER BY 2, 1 LIMIT 20 OFFSET 5" true]
   ["SELECT COUNT(*), SUM(x) FROM (SELECT k AS x FROM t UNION ALL SELECT k FROM r UNION ALL SELECT k FROM s) u" false]
   ["SELECT id FROM t WHERE k IN (SELECT k FROM r WHERE w > 9 UNION ALL SELECT k FROM s WHERE w < 1)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k AND r.w < 1 UNION ALL SELECT 1 FROM s WHERE s.k = t.k AND s.w > 9)" false]
   ["WITH u AS (SELECT k, name FROM r UNION ALL SELECT k, name FROM s) SELECT t.id, u.name FROM t JOIN u ON u.k = t.k WHERE t.g = 3" false]
   ["SELECT DISTINCT g FROM t UNION ALL SELECT DISTINCT k FROM s" false]
   ["SELECT k FROM s UNION ALL SELECT k FROM t LIMIT 100" false]
   ["SELECT id FROM t UNION ALL SELECT k / g FROM t" false]
   ;; uncorrelated subqueries (precomputed in vectorized mode)
   ["SELECT id FROM t WHERE k IN (SELECT k FROM r WHERE w > 5)" false]
   ["SELECT id, k NOT IN (SELECT k FROM r WHERE w > 5) FROM t" false]
   ["SELECT id, k NOT IN (SELECT k FROM r WHERE k IS NOT NULL AND w > 5) FROM t WHERE g = 1" false]
   ["SELECT id, k IN (SELECT k FROM r WHERE w > 100), k NOT IN (SELECT k FROM r WHERE w > 100) FROM t" false]
   ["SELECT id FROM t WHERE s IN (SELECT name FROM r) OR u IN (SELECT name FROM s)" false]
   ["SELECT id, s NOT IN (SELECT CASE WHEN k > 300 THEN NULL ELSE 'red' END FROM r) FROM t" false]
   ["SELECT id FROM t WHERE d IN (SELECT w FROM r) AND f NOT IN (SELECT k FROM s WHERE k IS NOT NULL)" false]
   ["SELECT id FROM t WHERE dt IN (SELECT ts FROM t WHERE g = 2) OR ts IN (SELECT dt FROM t WHERE g = 3)" false]
   ["SELECT id, (SELECT MAX(w) FROM r) - d, (SELECT MIN(w) FROM r WHERE w > 100) FROM t" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE w > 9) AND NOT EXISTS (SELECT 1 FROM s WHERE w > 100)" false]
   ["SELECT g, COUNT(*) FROM t GROUP BY g HAVING COUNT(*) > (SELECT COUNT(*) FROM s) * 4" false]
   ["SELECT id FROM t WHERE k IN (SELECT k FROM r WHERE w > (SELECT AVG(w) FROM s))" false]
   ["SELECT id, (SELECT COUNT(*) FROM r WHERE r.k = t.k AND r.w > (SELECT AVG(w) FROM r)) FROM t WHERE g = 4" false]
   ["SELECT id FROM t WHERE g = 99 AND k = (SELECT k FROM r)" false]
   ["SELECT id FROM t WHERE g = 99 AND k IN (SELECT k / 0 FROM r)" false]
   ["SELECT id, k / g IN (SELECT k FROM r WHERE w > 100) FROM t" false]
   ["SELECT id FROM t WHERE k = (SELECT k FROM r WHERE w > 1)" false]
   ;; correlated EXISTS as a precomputed key set (vectorized mode)
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k AND r.w > 5)" false]
   ["SELECT id, NOT EXISTS (SELECT * FROM r WHERE r.k = t.k) FROM t" false]
   ["SELECT id FROM t WHERE NOT EXISTS (SELECT name FROM r WHERE t.d = r.w) AND g = 1" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.name = t.u OR r.name = 'n3' AND r.k = t.g)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.name = t.s)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k + 1 AND r.name IS NOT NULL)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k AND 10 / (r.k - 7) > 1)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k LIMIT 0)" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 / 0 FROM r WHERE r.k = t.k)" false]
   ["SELECT g, COUNT(*) FROM t WHERE EXISTS (SELECT 1 FROM s WHERE s.k = t.g) GROUP BY g" false]
   ["SELECT id FROM t WHERE EXISTS (SELECT 1 FROM r WHERE r.k = t.k AND EXISTS (SELECT 1 FROM s WHERE s.k = r.k))" false]
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
    (is (contains? (ops "SELECT id FROM t UNION ALL SELECT k FROM r" {:threads 4}) "UnionAll"))
    (is (not (contains? (ops "SELECT id FROM t WHERE g = 1" {:threads 1}) "Gather")))))
