(ns polyquery.util.json-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.util.json :as json]))

(defn- syntax-error? [s]
  (try (json/read-str s) false
       (catch clojure.lang.ExceptionInfo e (json/syntax-error? e))))

(deftest reads-values
  (is (= {"a" [1 2.5 "x" true false nil]} (json/read-str "{\"a\": [1, 2.5, \"x\", true, false, null]}")))
  (is (= "é\"\\/\n" (json/read-str "\"\\u00e9\\\"\\\\\\/\\n\"")))
  (is (= 12345678901234567890N (biginteger (json/read-str "12345678901234567890"))))
  (is (= -0.5 (json/read-str " -5e-1 "))))

(deftest rejects-invalid-json
  (doseq [s ["" "{" "[1,]" "{\"a\":1,}" "01" "1." ".5" "NaN" "'x'" "{a:1}" "[1] 2" "\"\t\"" "tru"]]
    (testing s (is (syntax-error? s)))))

(deftest ingestion-number-keeps-text
  (let [n (json/read-str "1.50" {:number-fn json/ingest-number})]
    (is (json/json-number? n))
    (is (= "1.50" (str n)))))

(deftest writes-single-line-json
  (is (= "{\"a\":\"x\\ny\\\"\",\"b\":[1,2.5,null,true]}"
         (json/write-str (array-map "a" "x\ny\"" "b" [1 2.5 nil true]))))
  (is (= "0.0" (json/write-str -0.0)))
  (is (= "\"\\u0001\"" (json/write-str (str (char 1))))))
