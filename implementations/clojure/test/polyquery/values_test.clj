(ns polyquery.values-test
  (:require [clojure.test :refer [deftest is are]]
            [polyquery.test-util :refer [error-code]]
            [polyquery.types :as t]
            [polyquery.values :as v]))

(deftest calendar-round-trips
  (are [s] (= s (v/format-date (v/parse-date s)))
    "1970-01-01" "0001-01-01" "9999-12-31" "2024-02-29" "1969-12-31" "2000-03-01")
  (is (nil? (v/parse-date "2023-02-29")))
  (is (nil? (v/parse-date "0000-01-01")))
  (is (nil? (v/parse-date "2024-1-01")))
  (is (= 0 (v/parse-date "1970-01-01"))))

(deftest timestamps
  (is (= "2024-02-29 13:14:15.500000" (v/format-timestamp (v/parse-timestamp "2024-02-29T13:14:15.5"))))
  (is (= "1969-12-31 23:59:59.999999" (v/format-timestamp -1)))
  (is (nil? (v/parse-timestamp "2024-01-01 24:00:00")))
  (is (nil? (v/parse-timestamp "2024-01-01")))
  (is (some? (v/parse-timestamp "2024-01-01" true)))
  (is (nil? (v/parse-timestamp "2024-01-01 10:00:00.1234567"))))

(deftest decimals
  (is (= "-0.05" (v/dec->string -5 2)))
  (is (= "12" (v/dec->string 12 0)))
  (is (= 375 (v/dec-add 125 2 25 1)))
  (is (= "NUMERIC_OVERFLOW" (error-code (v/dec-add 999999999999999999 0 1 0))))
  ;; exact even when an operand overflows a long after rescaling
  (is (= 1 (v/dec-add 1 0 -999999999999999999 18)))
  (is (= 235 (v/dec-rescale 2345 3 5 2)))
  (is (= -235 (v/dec-rescale -2345 3 5 2)))
  (is (neg? (v/dec-compare 1 0 15 1)))
  (is (= 1050 (v/parse-decimal-exact "+10.5" 4 2)))
  (is (nil? (v/parse-decimal-exact "10.500" 5 2)))
  (is (nil? (v/parse-decimal-exact "1000" 5 2))))

(deftest casts
  (let [cast (fn [from to x] ((v/cast-fn from to) x))]
    (is (= 3 (cast (t/decimal 3 2) :int64 375)))
    (is (= -3 (cast (t/decimal 3 2) :int64 -375)))
    (is (= 3 (cast :float64 (t/decimal 3 0) 2.5)))
    (is (= 101 (cast :string (t/decimal 4 2) "1.005")))
    (is (= true (cast :string :boolean " TRUE ")))
    (is (= "CONVERSION_ERROR" (error-code (cast :string :int64 "abc"))))
    (is (= "NUMERIC_OVERFLOW" (error-code (cast :string :int64 "9223372036854775808"))))
    (is (= "NUMERIC_OVERFLOW" (error-code (cast :float64 :int64 1e19))))
    (is (= "1.50" (cast (t/decimal 3 2) :string 150)))
    (is (not (v/castable? :date :int64)))
    (is (v/castable? :timestamp :date))))
