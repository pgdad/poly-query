;; Generates the training run of the JVM's ahead-of-time cache (`make build`,
;; see README "Startup: AOT cache"): synthetic tables and a session script
;; (requests.jsonl) of generic query shapes — filters, aggregations,
;; GROUP BY, joins, sorts, DISTINCT, subqueries, string and date functions —
;; each repeated so that the JIT profiles of the hot loops are recorded.
;;
;; usage: clojure -M script/training.clj DIR
(ns training
  (:require [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (java.util Random)))

(def ^:private letters "abcdefghijklmnopqrstuvwxyz")

(defn- rand-word [^Random rnd lo hi]
  (apply str (repeatedly (+ lo (.nextInt rnd (- hi lo))) #(.charAt ^String letters (.nextInt rnd 26)))))

(defn- maybe [^Random rnd pct s] (if (< (.nextInt rnd 100) pct) "" s))

(defn- write-csv [dir name header n row-fn]
  (let [rnd (Random. (hash name))]
    (with-open [w (io/writer (io/file dir (str name ".csv")))]
      (.write w (str (str/join "," header) "\n"))
      (dotimes [i n]
        (.write w (str (str/join "," (row-fn rnd i)) "\n"))))))

(def ^:private cats ["food" "travel" "books" "games" "garden" "health" "music" "sports" "toys" "tools" "auto" "home"])
(def ^:private tags ["new" "open" "closed" "held" "void"])
(def ^:private regions ["north" "south" "east" "west" "center" "coast" "hills" "plains"])

(defn- timestamp [^Random rnd]
  (format "2024-%02d-%02d %02d:%02d:%02d" (inc (.nextInt rnd 12)) (inc (.nextInt rnd 28))
          (.nextInt rnd 24) (.nextInt rnd 60) (.nextInt rnd 60)))

(def tables
  {"fact" {:rows 300000
           :schema [["id" "INT64"] ["k1" "INT64"] ["k2" "INT64"] ["grp" "INT64"] ["amt" "DECIMAL(12,2)"]
                    ["fee" "DECIMAL(10,2)"] ["x" "FLOAT64"] ["cat" "STRING"] ["tag" "STRING"]
                    ["code" "STRING"] ["ts" "TIMESTAMP"] ["d" "DATE"] ["flag" "BOOLEAN"] ["n" "INT64"]]
           :row (fn [^Random rnd i]
                  [(inc i) (.nextInt rnd 1000) (.nextInt rnd 50000) (.nextInt rnd 20)
                   (format "%.2f" (* 1000.0 (.nextDouble rnd))) (format "%.2f" (* 5.0 (.nextDouble rnd)))
                   (format "%.4f" (- (* 200.0 (.nextDouble rnd)) 100.0))
                   (cats (.nextInt rnd (count cats))) (tags (.nextInt rnd (count tags)))
                   (rand-word rnd 1 11) (timestamp rnd)
                   (format "2023-%02d-%02d" (inc (.nextInt rnd 12)) (inc (.nextInt rnd 28)))
                   (if (.nextBoolean rnd) "true" "false")
                   (maybe rnd 40 (.nextInt rnd 1000))])}
   "dim" {:rows 50000
          :schema [["k" "INT64"] ["name" "STRING"] ["region" "STRING"] ["tier" "STRING"]
                   ["score" "DECIMAL(8,2)"] ["active" "BOOLEAN"]]
          :row (fn [^Random rnd i]
                 [i (rand-word rnd 4 9) (regions (.nextInt rnd (count regions)))
                  (["gold" "silver" "bronze"] (.nextInt rnd 3))
                  (maybe rnd 10 (format "%.2f" (* 100.0 (.nextDouble rnd))))
                  (if (.nextBoolean rnd) "true" "false")])}
   "small" {:rows 1000
            :schema [["id" "INT64"] ["label" "STRING"] ["parent" "INT64"]]
            :row (fn [^Random rnd i]
                   [(.nextInt rnd 1000) (cats (.nextInt rnd (count cats))) (maybe rnd 20 (.nextInt rnd 1000))])}})

(def queries
  ["SELECT COUNT(*), SUM(amt) FROM fact WHERE k1 = 17"
   "SELECT COUNT(*), SUM(amt), MAX(fee) FROM fact WHERE tag <> 'void'"
   "SELECT COUNT(*), AVG(amt) FROM fact WHERE ts >= TIMESTAMP '2024-03-01 00:00:00' AND ts < TIMESTAMP '2024-04-01 00:00:00'"
   "SELECT SUM(amt * 2 - fee), MIN(amt), MAX(amt), AVG(k1), SUM(x), MIN(x) FROM fact"
   "SELECT COUNT(*) FROM fact WHERE k2 BETWEEN 100 AND 20000 AND grp IN (1, 3, 5) AND NOT flag"
   "SELECT COUNT(*), SUM(n) FROM fact WHERE n IS NOT NULL OR code LIKE 'a%'"
   "SELECT cat, COUNT(*), SUM(amt), AVG(amt), MIN(ts), MAX(d) FROM fact GROUP BY cat ORDER BY cat"
   "SELECT k2, COUNT(*) AS c, SUM(amt) AS s FROM fact GROUP BY k2 ORDER BY s DESC, k2 LIMIT 10"
   "SELECT grp % 7 AS g, tag, COUNT(*), SUM(fee) FROM fact GROUP BY grp % 7, tag ORDER BY g, tag"
   "SELECT k1, AVG(x), MAX(amt) FROM fact WHERE flag GROUP BY k1 HAVING COUNT(*) > 100"
   "SELECT COUNT(DISTINCT k2), COUNT(DISTINCT cat) FROM fact"
   "SELECT d.region, d.tier, COUNT(*), SUM(f.amt) FROM fact f JOIN dim d ON d.k = f.k2 GROUP BY d.region, d.tier ORDER BY d.region, d.tier"
   "SELECT s.label, COUNT(*), SUM(f.fee) FROM fact f JOIN dim d ON d.k = f.k2 JOIN small s ON s.id = f.k1 WHERE d.active GROUP BY s.label"
   "SELECT COUNT(*) FROM dim d LEFT JOIN fact f ON f.k2 = d.k WHERE f.id IS NULL"
   "SELECT f.id, d.name FROM fact f JOIN dim d ON d.k = f.k2 WHERE f.k1 < 3"
   "SELECT id, code FROM fact ORDER BY k2 LIMIT 50"
   "SELECT id, code FROM fact ORDER BY code, id"
   "SELECT k1, x, id FROM fact ORDER BY k1 DESC, x, id"
   "SELECT id, amt FROM fact ORDER BY amt DESC, id LIMIT 20"
   "SELECT name, score FROM dim ORDER BY score DESC NULLS LAST, name"
   "SELECT k1, DATE_TRUNC('day', ts) AS h, AVG(x), MAX(fee) FROM fact WHERE k1 <= 20 GROUP BY k1, DATE_TRUNC('day', ts) ORDER BY k1, h LIMIT 100"
   "SELECT COUNT(*), MAX(LENGTH(code)), SUM(CASE WHEN code LIKE '%e%' THEN 1 ELSE 0 END) FROM fact WHERE UPPER(tag) = 'OPEN'"
   "SELECT YEAR(d), MONTH(ts), COUNT(*) FROM fact GROUP BY YEAR(d), MONTH(ts)"
   "SELECT SUBSTR(code, 1, 2), LOWER(cat), COALESCE(n, 0), ROUND(x, 1), ABS(x), CAST(k1 AS STRING) FROM fact WHERE id < 2000"
   "WITH t AS (SELECT k2, SUM(amt) AS total FROM fact GROUP BY k2) SELECT COUNT(*) FROM t WHERE total > (SELECT AVG(total) FROM t)"
   "SELECT COUNT(*) FROM fact WHERE k2 IN (SELECT k FROM dim WHERE tier = 'gold')"
   "SELECT COUNT(*) FROM small s WHERE EXISTS (SELECT 1 FROM small p WHERE p.id = s.parent)"
   "SELECT DISTINCT cat, tag FROM fact"
   "SELECT tag, COUNT(*) FROM (SELECT tag, k1 FROM fact WHERE x > 0) q GROUP BY tag"
   "SELECT id, cat FROM fact WHERE cat = 'books' UNION ALL SELECT id, label FROM small"])

(defn- json-str [x]
  (cond
    (string? x) (str "\"" (str/replace x "\"" "\\\"") "\"")
    (map? x) (str "{" (str/join "," (map (fn [[k v]] (str (json-str (name k)) ":" (json-str v))) x)) "}")
    (sequential? x) (str "[" (str/join "," (map json-str x)) "]")
    :else (str x)))

(defn -main [dir]
  (.mkdirs (io/file dir))
  (doseq [[name {:keys [rows schema row]}] tables]
    (write-csv dir name (map first schema) rows row))
  (let [id (atom 0)
        req (fn [m] (json-str (assoc m :id (swap! id inc))))]
    (with-open [w (io/writer (io/file dir "requests.jsonl"))]
      (doseq [[name {:keys [schema]}] tables]
        (.write w (str (req {:op "load" :table name :path (str name ".csv") :format "csv"
                             :schema (mapv (fn [[n t]] {:name n :type t}) schema)})
                       "\n")))
      (doseq [sql ["CREATE INDEX tr_k1 ON fact (k1) USING HASH"
                   "CREATE INDEX tr_ts ON fact (ts) USING BTREE"]]
        (.write w (str (req {:op "query" :sql sql}) "\n")))
      ;; the last rounds also serialize the result rows
      (dotimes [i 12]
        (doseq [sql queries]
          (.write w (str (req (cond-> {:op "query" :sql sql}
                                (< i 10) (assoc :options {:result "count"})))
                         "\n")))))))

(apply -main *command-line-args*)
