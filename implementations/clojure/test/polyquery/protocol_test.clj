(ns polyquery.protocol-test
  (:require [clojure.java.io :as io]
            [clojure.test :refer [deftest is testing]]
            [polyquery.protocol :as protocol])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defn- temp-dir ^File []
  (.toFile (Files/createTempDirectory "pq-test" (make-array FileAttribute 0))))

(defn- state [dir]
  (protocol/make-state {:data-dir dir :test-functions? false
                        :limits {:max-ingest-bytes 1000000 :max-table-rows 1000
                                 :max-query-memory-mb 64}}))

(deftest catalog-operations
  (let [dir (temp-dir)
        st (state dir)
        req #(protocol/handle-request st %)]
    (spit (io/file dir "t.csv") "a,b\n1,x\n2,y\n")
    (is (= {"id" 7 "ok" true "table" "T" "row_count" 2
            "columns" [{"name" "a" "type" "INT64"} {"name" "b" "type" "STRING"}]}
           (req {"op" "load" "id" 7 "table" "T" "format" "csv" "path" "t.csv"})))
    (is (= "ALREADY_EXISTS" (get-in (req {"op" "load" "table" "t" "format" "csv" "path" "t.csv"}) ["error" "code"])))
    (is (= [{"name" "T" "row_count" 2}] (get (req {"op" "tables"}) "tables")))
    (is (= [[2 "y"]] (mapv vec (get (req {"op" "query" "sql" "SELECT * FROM t WHERE a = 2"}) "rows"))))
    (is (true? (get (req {"op" "drop" "table" "t"}) "ok")))
    (is (= "NOT_FOUND" (get-in (req {"op" "schema" "table" "t"}) ["error" "code"])))))

(deftest request-validation
  (let [st (state (temp-dir))
        code #(get-in (protocol/handle-request st %) ["error" "code"])]
    (doseq [[r c] [[{"op" "nope"} "INVALID_REQUEST"]
                   [{"op" "query"} "INVALID_REQUEST"]
                   [{"op" "query" "sql" 1} "INVALID_REQUEST"]
                   [[1 2] "INVALID_REQUEST"]
                   [{"op" "load" "table" "t" "format" "csv" "path" "/etc/passwd"} "ACCESS_DENIED"]
                   [{"op" "load" "table" "t" "format" "csv" "path" "a/../../x"} "ACCESS_DENIED"]
                   [{"op" "load" "table" "t" "format" "csv" "path" ""} "ACCESS_DENIED"]
                   [{"op" "load" "table" "t" "format" "csv" "path" "missing.csv"} "NOT_FOUND"]
                   [{"op" "sleep" "ms" 1} "INVALID_REQUEST"]
                   [{"op" "query" "sql" "SELECT 1" "options" {"mode" "quantum"}} "UNSUPPORTED"]
                   [{"op" "query" "sql" "SELECT 1" "options" {"join" "teleport"}} "UNSUPPORTED"]
                   [{"op" "query" "sql" "SELECT 1" "options" {"threads" 0}} "INVALID_REQUEST"]]]
      (testing (pr-str r) (is (= c (code r)))))))
