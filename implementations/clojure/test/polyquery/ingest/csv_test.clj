(ns polyquery.ingest.csv-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.ingest.csv :as csv]
            [polyquery.storage.table :as table]
            [polyquery.test-util :refer [error-code]]
            [polyquery.types :as t])
  (:import (java.io StringReader)))

(def limits {:max-table-rows 1000 :max-ingest-bytes 1000000})

(defn- load-csv
  ([text] (load-csv text {}))
  ([text opts]
   (csv/load-csv (StringReader. text) (merge {:name "t" :header? true :delimiter \, :limits limits} opts))))

(defn- types [tbl] (mapv (comp t/type-name :type) (:columns tbl)))
(defn- column [tbl i] (vec (table/column-array tbl i)))

(deftest inference
  (let [tbl (load-csv "b,i,f,d,ts,s,n\ntrue,1,1,2024-01-01,2024-01-01,x,\nFALSE,-2,2.5,2024-02-29,2024-01-01 10:00:00,1,\n")]
    (is (= ["BOOLEAN" "INT64" "FLOAT64" "DATE" "TIMESTAMP" "STRING" "STRING"] (types tbl)))
    (is (= [true false] (column tbl 0)))
    (is (= [1.0 2.5] (column tbl 2)))
    (is (= [nil nil] (column tbl 6))))
  (is (= ["FLOAT64"] (types (load-csv "n\n9223372036854775808\n"))))
  (is (= ["STRING"] (types (load-csv "v\n2023-02-29\n")))))

(deftest quoting-and-nulls
  (let [tbl (load-csv "id,s\r\n1,\"a,\"\"b\"\"\"\r\n2,\"\"\r\n3,\r\n4,\"x\ny\"")]
    (is (= ["a,\"b\"" "" nil "x\ny"] (column tbl 1))))
  (testing "quoted empty is NULL for non-string columns"
    (is (= [nil 1] (column (load-csv "n\n\"\"\n1\n") 0))))
  (testing "BOM and empty lines"
    (is (= [1 2] (column (load-csv "﻿x\n1\n\n2") 0)))))

(deftest explicit-schema
  (let [schema [(table/->Column "a" (t/decimal 5 2)) (table/->Column "b" :string)]]
    (is (= [150 -5] (column (load-csv "a,b\n1.5,x\n-.05,y\n" {:schema schema}) 0)))
    (is (= "CONVERSION_ERROR" (error-code (load-csv "a,b\n1.505,x\n" {:schema schema}))))
    (is (= "INGEST_ERROR" (error-code (load-csv "a,c\n1,x\n" {:schema schema}))))
    (is (= [1 2] (column (load-csv "1,x\n2,y\n" {:schema [(table/->Column "n" :int64) (table/->Column "s" :string)]
                                                 :header? false}) 0)))))

(deftest structural-errors
  (doseq [text ["a,b\n1\n" "a,a\n1,2\n" "a,\n1,2\n" "a\n\"open\n" "a\n\"x\"y\n"]]
    (testing text (is (= "INGEST_ERROR" (error-code (load-csv text))))))
  (is (= "RESOURCE_LIMIT" (error-code (load-csv (apply str "a\n" (repeat 1001 "1\n")))))))
