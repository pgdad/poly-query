(ns polyquery.api-test
  (:require [clojure.java.io :as io]
            [clojure.test :refer [deftest is testing]]
            [polyquery.api :as pq])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)
           (java.time LocalDate LocalDateTime)))

(defn- temp-dir ^File []
  (.toFile (Files/createTempDirectory "pq-api-test" (make-array FileAttribute 0))))

(defmacro ^:private code-of
  "The API error code thrown by body, or :no-error."
  [& body]
  `(try ~@body :no-error
        (catch clojure.lang.ExceptionInfo e# (or (pq/error-code e#) (throw e#)))))

(deftest typed-values
  (with-open [db (pq/create)]
    (pq/load! db "t" {:text "i,d,f,s,b,day\n1,10.50,1.5e0,x,true,2026-01-02\n,,,\"\",,\n"
                      :schema [["i" "INT64"] ["d" "DECIMAL(18,2)"] ["f" "FLOAT64"] ["s" "STRING"]
                               ["b" "BOOLEAN"] ["day" "DATE"]]})
    (let [r (pq/query db "SELECT i, d, f, s, b, day, CAST(day AS TIMESTAMP) AS ts FROM t ORDER BY i NULLS LAST")]
      (is (= ["i" "d" "f" "s" "b" "day" "ts"] (pq/column-names r)))
      (is (= ["INT64" "DECIMAL(18,2)" "FLOAT64" "STRING" "BOOLEAN" "DATE" "TIMESTAMP"] (pq/column-types r)))
      (is (= 2 (pq/row-count r)))
      (let [[row nulls] (pq/rows r)]
        (is (= [1 10.50M 1.5 "x" true (LocalDate/of 2026 1 2) (LocalDateTime/of 2026 1 2 0 0)] row))
        (is (instance? Long (first row)))
        (is (= 2 (.scale ^BigDecimal (second row))))
        (is (= [nil nil nil "" nil nil nil] nulls))))
    (is (= [{"n" 2}] (pq/row-maps (pq/query db "SELECT COUNT(*) AS n FROM t"))))))

(deftest errors-carry-codes-and-leave-the-instance-usable
  (with-open [db (pq/create)]
    (is (= "PARSE_ERROR" (code-of (pq/query db "SELEC 1"))))
    (is (= "SEMANTIC_ERROR" (code-of (pq/query db "SELECT * FROM nowhere"))))
    (is (= "NOT_FOUND" (code-of (pq/drop! db "nowhere"))))
    (is (= "NOT_FOUND" (code-of (pq/schema db "nowhere"))))
    (is (= "ACCESS_DENIED" (code-of (pq/load! db "t" {:path "../x.csv"}))))
    (is (= "RESOURCE_LIMIT" (code-of (pq/query db "SELECT 1 UNION ALL SELECT 2" {:max-rows 1}))))
    (is (= "INVALID_REQUEST" (code-of (pq/query db "SELECT 1" {:max-rows -1}))))
    (pq/load! db "t" {:text "a\n1\n"})
    (is (= "ALREADY_EXISTS" (code-of (pq/load! db "t" {:text "a\n1\n"}))))
    (is (= [[1]] (pq/rows (pq/query db "SELECT a FROM t"))))
    (testing "the message is the exception's message"
      (let [e (try (pq/query db "SELECT nope FROM t") (catch Exception e e))]
        (is (string? (ex-message e)))
        (is (= "SEMANTIC_ERROR" (pq/error-code e)))))))

(deftest load-rows-save-open-drop
  (let [dir (temp-dir)]
    (with-open [db (pq/create {:data-dir dir :threads 2 :max-query-memory-mb 64})]
      (pq/load-rows! db "r" [["id" "INT64"] ["d" "DATE"] ["a" "DECIMAL(18,2)"] ["s" "STRING"]]
                     [[1 (LocalDate/of 2026 1 2) 1.5M "x"] [2 nil nil ""]])
      (let [saved (pq/save! db "r" "r.pqcf")]
        (is (= {:path "r.pqcf" :bytes (.length (io/file dir "r.pqcf"))} saved)))
      (is (= 2 (:row-count (pq/open! db "r2" "r.pqcf"))))
      (is (= [[1 (LocalDate/of 2026 1 2) 1.50M "x"] [2 nil nil ""]]
             (pq/rows (pq/query db "SELECT * FROM r2 ORDER BY id"))))
      (is (= [{:name "r" :row-count 2} {:name "r2" :row-count 2}] (pq/tables db)))
      (is (= [{:name "id" :type "INT64"} {:name "d" :type "DATE"} {:name "a" :type "DECIMAL(18,2)"}
              {:name "s" :type "STRING"}]
             (:columns (pq/schema db "r2"))))
      (is (= "ALREADY_EXISTS" (code-of (pq/open! db "r2" "r.pqcf"))))
      (is (= 2 (:row-count (pq/open! db "r2" "r.pqcf" {:replace true}))))
      (pq/drop! db "r2")
      (is (= ["r"] (map :name (pq/tables db))))
      (testing "value checks"
        (is (= "INVALID_REQUEST" (code-of (pq/load-rows! db "x" [["a" "INT64"]] [["1"]]))))
        (is (= "CONVERSION_ERROR" (code-of (pq/load-rows! db "x" [["a" "DECIMAL(18,2)"]] [[1.005M]]))))
        (is (= "NUMERIC_OVERFLOW" (code-of (pq/load-rows! db "x" [["a" "DECIMAL(4,2)"]] [[100M]]))))
        (is (= "INVALID_REQUEST" (code-of (pq/load-rows! db "x" [["a" "INT64"]] [[1 2]]))))
        (is (= "INGEST_ERROR" (code-of (pq/load-rows! db "x" [["a" "INT64"] ["A" "INT64"]] []))))))))

(deftest close
  (let [db (pq/create)]
    (pq/load! db "t" {:text "a\n1\n"})
    (pq/close db)
    (pq/close db)
    (is (pq/closed? db))
    (is (= "INVALID_REQUEST" (code-of (pq/query db "SELECT 1"))))))

(deftest independent-instances
  (with-open [a (pq/create) b (pq/create)]
    (pq/load! a "t" {:text "x\n1\n"})
    (is (= "SEMANTIC_ERROR" (code-of (pq/query b "SELECT * FROM t"))))
    (is (= [[1]] (pq/rows (pq/query a "SELECT * FROM t"))))))

(deftest concurrent-queries
  (with-open [db (pq/create)]
    (pq/load-rows! db "n" [["i" "INT64"]] (map vector (range 10000)))
    (let [results (doall (pmap (fn [_] (pq/rows (pq/query db "SELECT SUM(i) FROM n"))) (range 16)))]
      (is (every? #(= [[49995000]] %) results)))))

(deftest create-validates-its-configuration
  (is (= "INVALID_REQUEST" (code-of (pq/create {:threads 0}))))
  (is (= "INVALID_REQUEST" (code-of (pq/create {:data-dir 5})))))
