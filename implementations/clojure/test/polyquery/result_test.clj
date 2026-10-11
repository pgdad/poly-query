(ns polyquery.result-test
  (:require [clojure.test :refer [deftest is]]
            [polyquery.result :as result]
            [polyquery.types :as t]
            [polyquery.util.json :as json]
            [polyquery.values :as v]))

(def types [:int64 :float64 :boolean :string (t/decimal 12 2) (t/decimal 4 0) (t/decimal 30 5)
            :date :timestamp :null])

(def rows
  [(object-array [1 1.5 true "a" 1234 7 (biginteger 123456789) 0 0 nil])
   (object-array [Long/MIN_VALUE -0.0 false "q\"\\\n\u0001\ud800x" -5 -7 (biginteger -5) -719162
                  (* 86400000000 -1) nil])
   (object-array [nil nil nil nil nil nil nil nil nil nil])
   (object-array [-42 1e-7 true "ünï" Long/MIN_VALUE 0 (biginteger 0) 2932896
                  (+ (* 86400000000 20000) 1234567) nil])])

(defn- collect [encoding]
  (let [sink (result/sink encoding types)]
    (doseq [r rows] (result/accept! sink r))
    (result/rows sink)))

(deftest json-text-matches-json-values
  (is (= (json/write-str (collect :values)) (json/write-str (collect :json-text)))))

(deftest canonical-text
  (is (= "[[1,1.5,true,\"a\",\"12.34\",\"7\",\"1234.56789\",\"1970-01-01\",\"1970-01-01 00:00:00\",null]]"
         (json/write-str (let [s (result/sink :json-text types)]
                           (result/accept! s (first rows))
                           (result/rows s))))))

(deftest formatting-helpers
  (is (= "-0.05" (v/dec->string -5 2)))
  (is (= "0.000" (v/dec->string 0 3)))
  (is (= "-92233720368547758.08" (v/dec->string Long/MIN_VALUE 2)))
  (is (= "0001-01-01" (v/format-date -719162)))
  (is (= "9999-12-31" (v/format-date 2932896)))
  (is (= "1969-12-31 23:59:59.999999" (v/format-timestamp -1)))
  (is (= "2024-02-29 12:00:00" (v/format-timestamp (* 1000000 (+ (* 86400 19782) 43200)))))
  (is (= [2024 2 29] (v/civil-from-days 19782)))
  (is (= [2024 2 29] [(v/year-of-days 19782) (v/month-of-days 19782) (v/day-of-days 19782)])))
