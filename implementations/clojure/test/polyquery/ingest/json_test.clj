(ns polyquery.ingest.json-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.ingest.json :as json]
            [polyquery.storage.table :as table]
            [polyquery.test-util :refer [error-code]]
            [polyquery.types :as t])
  (:import (java.io StringReader)))

(def limits {:max-table-rows 1000 :max-ingest-bytes 1000000})

(defn- load-json [text & {:keys [schema jsonl?]}]
  ((if jsonl? json/load-jsonl json/load-json)
   (StringReader. text) {:name "t" :schema schema :limits limits}))

(defn- types [tbl] (mapv (comp t/type-name :type) (:columns tbl)))

(deftest inference
  (let [tbl (load-json "[{\"a\":1,\"b\":1.5,\"c\":\"2024-01-01\",\"d\":true},{\"b\":2,\"c\":\"2024-01-01 10:00:00\",\"e\":null}]")]
    (is (= ["a" "b" "c" "d" "e"] (mapv :name (:columns tbl))))
    (is (= ["INT64" "FLOAT64" "TIMESTAMP" "BOOLEAN" "STRING"] (types tbl)))
    (is (= [1 nil] (vec (table/column-array tbl 0))))))

(deftest jsonl
  (let [tbl (load-json "{\"a\":\"x\"}\n\n  {\"a\":\"y\"}  \n" :jsonl? true)]
    (is (= ["x" "y"] (vec (table/column-array tbl 0))))))

(deftest explicit-schema
  (let [schema [(table/->Column "amt" (t/decimal 8 3))]]
    (is (= [12500 -125] (vec (table/column-array (load-json "[{\"amt\":12.5},{\"amt\":\"-0.125\"}]" :schema schema) 0))))
    (is (= "INGEST_ERROR" (error-code (load-json "[{\"amt\":1,\"x\":2}]" :schema schema))))
    (is (= "CONVERSION_ERROR" (error-code (load-json "[{\"amt\":true}]" :schema schema))))))

(deftest errors
  (doseq [text ["{\"a\":1}" "[{\"a\":1},2]" "[{\"a\":1,\"a\":2}]" "[{\"a\":[1]}]" "[{\"a\":1},{\"a\":\"x\"}]"
                "[{\"a\":1},]" "[{\"\":1}]"]]
    (testing text (is (= "INGEST_ERROR" (error-code (load-json text)))))))
