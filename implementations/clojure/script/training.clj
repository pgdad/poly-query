;; Writes the AOT-cache training workload (invoked by `make build`):
;;   clojure -M script/training.clj OUT-DIR
;; OUT-DIR receives synthetic CSV tables (deterministic pseudo-random data)
;; and requests.jsonl, a protocol session that `make build` replays through
;; bin/polyquery with -XX:AOTCacheOutput. The queries are generic analytics
;; shapes over these synthetic tables (filters, aggregation, grouping, joins,
;; sorts, subqueries, functions, indexes, storage, every execution mode) —
;; deliberately not the benchmark workload's queries.
(ns training
  (:require [clojure.java.io :as io]
            [clojure.string :as str])
  (:import (java.io Writer)
           (java.util SplittableRandom)))

(set! *warn-on-reflection* true)

(def ^:private fact-rows 250000)
(def ^:private dim-rows 20000)
(def ^:private wide-rows 40000)
(def ^:private wide-cols 40)

(def ^:private regions ["north" "south" "east" "west" "central" "islands"])
(def ^:private kinds ["alpha" "beta" "gamma" "delta" "epsilon" "zeta" "eta" "theta"
                      "iota" "kappa" "lambda" "mu" "nu" "xi" "omicron" "pi"])
(def ^:private states ["new" "open" "held" "closed" "void"])

(defn- pick [^SplittableRandom r v] (nth v (.nextInt r (count v))))

(defn- money ^String [^SplittableRandom r ^long max-cents]
  (let [c (.nextLong r max-cents)]
    (format "%d.%02d" (quot c 100) (rem c 100))))

(defn- date-str ^String [^long day]
  (str (.plusDays (java.time.LocalDate/of 2021 1 1) day)))

(defn- ts-str ^String [^long sec ^long micros]
  (let [t (.plusSeconds (java.time.LocalDateTime/of 2021 1 1 0 0 0) sec)]
    (format "%s %02d:%02d:%02d.%06d" (.toLocalDate t) (.getHour t) (.getMinute t) (.getSecond t) micros)))

(defn- write-table! [dir name header row-fn n]
  (with-open [^Writer w (io/writer (io/file dir (str name ".csv")))]
    (.write w (str (str/join "," header) "\n"))
    (dotimes [i n]
      (.write w (str (str/join "," (row-fn i)) "\n")))))

(defn- write-tables! [dir]
  (let [r (SplittableRandom. 20261011)]
    (write-table! dir "fact"
                  ["id" "dim_id" "small_id" "kind" "state" "qty" "price" "cost" "ratio" "at" "day" "flag" "opt" "note" "code"]
                  (fn [^long i]
                    [(inc i) (inc (.nextInt r dim-rows)) (.nextInt r 64) (pick r kinds) (pick r states)
                     (- (.nextInt r 1000) 100) (money r 1000000) (money r 5000) (.nextDouble r)
                     (ts-str (.nextLong r (* 3 365 86400)) (.nextInt r 1000000)) (date-str (.nextInt r 1000))
                     (if (.nextBoolean r) "true" "false")
                     (if (< (.nextInt r 10) 4) "" (.nextInt r 100000))
                     (if (< (.nextInt r 10) 3) "" (str "n" (.nextInt r 50)))
                     (format "c%07d" (.nextInt r 10000000))])
                  fact-rows)
    (write-table! dir "dim"
                  ["dim_id" "region" "label" "opened" "budget" "active"]
                  (fn [^long i]
                    [(inc i) (pick r regions) (str "d" (.nextInt r 900)) (date-str (.nextInt r 2000))
                     (money r 10000000) (if (zero? (.nextInt r 4)) "false" "true")])
                  dim-rows)
    (write-table! dir "small" ["small_id" "name"] (fn [^long i] [i (str "s" i)]) 64)
    (write-table! dir "wide_t"
                  (cons "id" (map #(format "w%02d" %) (range wide-cols)))
                  (fn [^long i]
                    (cons i (for [c (range wide-cols)]
                              (case (int (mod c 5))
                                0 (.nextInt r 100000)
                                1 (.nextDouble r)
                                2 (pick r kinds)
                                3 (if (.nextBoolean r) "true" "false")
                                4 (money r 100000)))))
                  wide-rows)))

(def ^:private schemas
  {"fact" [["id" "INT64"] ["dim_id" "INT64"] ["small_id" "INT64"] ["kind" "STRING"] ["state" "STRING"]
           ["qty" "INT64"] ["price" "DECIMAL(12,2)"] ["cost" "DECIMAL(10,2)"] ["ratio" "FLOAT64"]
           ["at" "TIMESTAMP"] ["day" "DATE"] ["flag" "BOOLEAN"] ["opt" "INT64"] ["note" "STRING"] ["code" "STRING"]]
   "dim" [["dim_id" "INT64"] ["region" "STRING"] ["label" "STRING"] ["opened" "DATE"]
          ["budget" "DECIMAL(14,2)"] ["active" "BOOLEAN"]]
   "small" [["small_id" "INT64"] ["name" "STRING"]]
   "wide_t" (cons ["id" "INT64"]
                  (for [c (range wide-cols)]
                    [(format "w%02d" c) (["INT64" "FLOAT64" "STRING" "BOOLEAN" "DECIMAL(12,2)"] (mod c 5))]))})

(defn- json-str [^String s]
  (str "\"" (-> s (str/replace "\\" "\\\\") (str/replace "\"" "\\\"") (str/replace "\n" "\\n")) "\""))

(defn- json [v]
  (cond
    (string? v) (json-str v)
    (map? v) (str "{" (str/join "," (map (fn [[k x]] (str (json-str (name k)) ":" (json x))) v)) "}")
    (sequential? v) (str "[" (str/join "," (map json v)) "]")
    (nil? v) "null"
    :else (str v)))

(def ^:private queries
  "Generic analytics shapes over the synthetic tables."
  ["SELECT COUNT(*) FROM fact"
   "SELECT COUNT(*), SUM(price), MIN(cost), MAX(cost) FROM fact WHERE small_id = 7"
   "SELECT COUNT(*), SUM(qty), AVG(ratio) FROM fact WHERE state <> 'void' AND qty > 10"
   "SELECT COUNT(*), MAX(price) FROM fact WHERE at >= TIMESTAMP '2022-01-01 00:00:00' AND at < TIMESTAMP '2022-02-01 00:00:00'"
   "SELECT COUNT(*), SUM(qty) FROM fact WHERE day BETWEEN DATE '2022-01-01' AND DATE '2022-06-30'"
   "SELECT SUM(price * 3 - cost), SUM(qty * 2 + 1), MIN(price), MAX(ratio), AVG(qty) FROM fact"
   "SELECT SUM(price + cost), SUM(price / 4), AVG(price - cost) FROM fact WHERE flag"
   "SELECT kind, COUNT(*), SUM(price), AVG(cost), MIN(day), MAX(at) FROM fact GROUP BY kind ORDER BY kind"
   "SELECT state, flag, COUNT(*), SUM(qty) FROM fact GROUP BY state, flag ORDER BY state, flag"
   "SELECT dim_id, COUNT(*) AS c, SUM(price) AS s FROM fact GROUP BY dim_id ORDER BY s DESC, dim_id LIMIT 7"
   "SELECT dim_id, COUNT(*) AS c FROM fact GROUP BY dim_id ORDER BY c DESC, dim_id LIMIT 5"
   "SELECT qty % 50 AS m, kind, COUNT(*), SUM(cost) FROM fact GROUP BY qty % 50, kind ORDER BY m, kind LIMIT 30"
   "SELECT small_id, SUM(ratio), MAX(qty) FROM fact GROUP BY small_id HAVING COUNT(*) > 10 ORDER BY small_id"
   "SELECT COUNT(DISTINCT dim_id), COUNT(DISTINCT small_id), COUNT(DISTINCT kind) FROM fact"
   "SELECT kind, COUNT(DISTINCT state), SUM(DISTINCT qty) FROM fact GROUP BY kind"
   "SELECT DISTINCT state, flag FROM fact"
   "SELECT d.region, d.active, COUNT(*), SUM(f.price) FROM fact f JOIN dim d ON d.dim_id = f.dim_id GROUP BY d.region, d.active ORDER BY d.region, d.active"
   "SELECT s.name, COUNT(*), SUM(f.qty * f.price) FROM fact f JOIN dim d ON d.dim_id = f.dim_id JOIN small s ON s.small_id = f.small_id WHERE d.region = 'east' GROUP BY s.name ORDER BY s.name"
   "SELECT COUNT(*) FROM dim d LEFT JOIN fact f ON f.dim_id = d.dim_id WHERE f.id IS NULL"
   "SELECT d.label, COUNT(f.id) FROM dim d LEFT JOIN fact f ON f.dim_id = d.dim_id AND f.qty > 800 GROUP BY d.label ORDER BY d.label LIMIT 20"
   "SELECT COUNT(*) FROM fact f, small s WHERE s.small_id = f.small_id AND s.name LIKE 's1%'"
   "SELECT id, code FROM fact ORDER BY code LIMIT 50"
   "SELECT id, price FROM fact ORDER BY price DESC, id LIMIT 20"
   "SELECT id, code FROM fact ORDER BY code, id"
   "SELECT small_id, ratio, id FROM fact ORDER BY small_id DESC, ratio, id"
   "SELECT id, at, day FROM fact WHERE qty < 0 ORDER BY at, id"
   "SELECT small_id, DATE_TRUNC('day', at) AS d, AVG(ratio), MAX(cost) FROM fact WHERE small_id <= 5 GROUP BY small_id, DATE_TRUNC('day', at) ORDER BY small_id, d LIMIT 60"
   "SELECT YEAR(day), MONTH(day), COUNT(*) FROM fact GROUP BY YEAR(day), MONTH(day) ORDER BY 1, 2"
   "SELECT DATE_TRUNC('month', day) AS m, HOUR(at), SUM(qty) FROM fact GROUP BY DATE_TRUNC('month', day), HOUR(at) ORDER BY m LIMIT 40"
   "SELECT COUNT(*), SUM(w00), MAX(w11), MIN(w24), SUM(w04) FROM wide_t WHERE w03 = true"
   "SELECT w02, AVG(w01), MAX(w09) FROM wide_t WHERE w13 = false GROUP BY w02 ORDER BY w02"
   "SELECT COUNT(opt), COUNT(note), SUM(opt), COUNT(*) FROM fact WHERE note IS NOT NULL OR flag = true"
   "SELECT COUNT(*), SUM(opt) FROM fact WHERE opt IS NULL AND note IS NULL"
   "WITH per AS (SELECT dim_id, SUM(price) AS total FROM fact GROUP BY dim_id) SELECT COUNT(*) FROM per WHERE total > (SELECT AVG(total) FROM per)"
   "SELECT COUNT(*) FROM fact WHERE dim_id IN (SELECT dim_id FROM dim WHERE region = 'west')"
   "SELECT COUNT(*) FROM fact WHERE price > (SELECT AVG(price) FROM fact WHERE kind = 'beta')"
   "SELECT COUNT(*) FROM dim d WHERE EXISTS (SELECT 1 FROM fact f WHERE f.dim_id = d.dim_id AND f.qty > 850)"
   "SELECT region, n FROM (SELECT region, COUNT(*) AS n FROM dim GROUP BY region) t WHERE n > 100 ORDER BY region"
   "SELECT COUNT(*), MAX(LENGTH(kind)), SUM(CASE WHEN kind LIKE '%ta%' THEN 1 ELSE 0 END) FROM fact WHERE UPPER(state) = 'OPEN'"
   "SELECT LOWER(kind), SUBSTR(code, 2, 3), COUNT(*) FROM fact WHERE kind IN ('alpha', 'beta', 'mu') GROUP BY LOWER(kind), SUBSTR(code, 2, 3) ORDER BY 1, 2 LIMIT 25"
   "SELECT CONCAT(kind, '-', state), COALESCE(note, 'none'), TRIM(label) FROM fact f JOIN dim d ON d.dim_id = f.dim_id WHERE f.id < 2000 ORDER BY f.id LIMIT 30"
   "SELECT REPLACE(kind, 'a', 'A'), NULLIF(state, 'new'), kind || state FROM fact WHERE id < 100"
   "SELECT ABS(qty), ROUND(price, 1), FLOOR(ratio * 10), CEIL(cost), SQRT(ABS(qty)), POWER(ratio, 2), MOD(qty, 7) FROM fact WHERE id <= 500"
   "SELECT CAST(qty AS FLOAT64), CAST(price AS INT64), CAST(day AS STRING), CAST('12' AS INT64) FROM fact WHERE id <= 300"
   "SELECT DATE_DIFF('day', day, DATE '2024-01-01'), DAY(at), MINUTE(at), SECOND(at) FROM fact WHERE id <= 300"
   "SELECT kind, SUM(qty) FROM fact WHERE flag GROUP BY kind UNION ALL SELECT state, SUM(qty) FROM fact WHERE NOT flag GROUP BY state"
   "SELECT id, qty, price FROM fact WHERE qty > 890 AND ratio < 0.5"
   "SELECT * FROM dim WHERE budget > 99000.00 ORDER BY dim_id"
   "SELECT f.id, d.region, f.price FROM fact f JOIN dim d ON d.dim_id = f.dim_id WHERE f.qty BETWEEN 10 AND 12"])

(def ^:private option-sets
  "Default options (as clients send them) dominate; the other execution
  models are exercised once."
  [{} {} {} {} {"result" "count"}
   {"mode" "row"} {"mode" "vectorized" "threads" 1} {"join" "merge"} {"optimize" false}])

(def ^:private index-requests
  [{"op" "query" "sql" "CREATE INDEX tr_fact_dim ON fact (dim_id) USING HASH"}
   {"op" "query" "sql" "CREATE INDEX tr_fact_at ON fact (at) USING BTREE"}
   {"op" "query" "sql" "SELECT COUNT(*), SUM(price) FROM fact WHERE dim_id = 1234"}
   {"op" "query" "sql" "SELECT COUNT(*) FROM fact WHERE at >= TIMESTAMP '2023-03-01 00:00:00' AND at < TIMESTAMP '2023-03-03 00:00:00'"}
   {"op" "explain" "sql" "SELECT COUNT(*) FROM fact WHERE dim_id = 99"}])

(defn- requests []
  (concat
   [{"op" "version"} {"op" "capabilities"}]
   (for [[t cols] schemas]
     {"op" "load" "table" t "format" "csv" "path" (str t ".csv")
      "schema" (for [[n ty] cols] {"name" n "type" ty})})
   [{"op" "load" "table" "j" "format" "jsonl" "data" "{\"a\":1,\"b\":\"x\",\"c\":1.5}\n{\"a\":2,\"b\":null,\"c\":2.5}\n"}
    {"op" "load" "table" "k" "format" "json" "data" "[{\"a\":1,\"d\":\"2024-01-02\"},{\"a\":3,\"d\":\"2024-02-03\"}]"}
    {"op" "load" "table" "inferred" "format" "csv" "data" "x,y,z\n1,2024-01-01,a\n2,2024-01-02 03:04:05,b\n"}
    {"op" "tables"} {"op" "schema" "table" "fact"} {"op" "stats" "table" "dim"}
    {"op" "query" "sql" "SELECT a, b, c FROM j ORDER BY a"}
    {"op" "query" "sql" "SELEKT nonsense"}
    {"op" "query" "sql" "SELECT missing_column FROM fact"}
    {"op" "query" "sql" "SELECT 1 / 0"}
    {"op" "save" "table" "dim" "path" "dim.pqcf"}
    {"op" "open" "table" "dim2" "path" "dim.pqcf" "options" {"mmap" true}}
    {"op" "query" "sql" "SELECT region, COUNT(*) FROM dim2 GROUP BY region ORDER BY region"}
    {"op" "drop" "table" "dim2"}]
   index-requests
   (for [opts option-sets, q queries]
     {"op" "query" "sql" q "options" opts})
   (for [q queries]
     {"op" "explain" "sql" q})
   ;; repeat with default options so the hot paths reach the optimizing JIT
   (for [_ (range 4), q queries]
     {"op" "query" "sql" q})))

(defn -main [out-dir]
  (let [dir (io/file out-dir)]
    (.mkdirs dir)
    (write-tables! dir)
    (with-open [^Writer w (io/writer (io/file dir "requests.jsonl"))]
      (doseq [[i req] (map-indexed vector (requests))]
        (.write w (str (json (assoc req "id" i)) "\n"))))))

(apply -main *command-line-args*)
