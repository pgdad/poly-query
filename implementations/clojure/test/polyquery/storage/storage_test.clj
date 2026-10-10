(ns polyquery.storage.storage-test
  "Column vectors, layouts, statistics and indexes."
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.storage.column :as col]
            [polyquery.storage.index :as index]
            [polyquery.storage.stats :as stats]
            [polyquery.storage.table :as table]
            [polyquery.values :as v])
  (:import (polyquery.storage.column ColumnVector)))

(defn- values [^ColumnVector cv] (vec (col/to-objects cv)))

(deftest typed-vectors
  (testing "every type round-trips through its typed vector, NULLs included"
    (doseq [[t xs] [[:int64 [1 nil -5]]
                    [[:decimal 10 2] [1050 nil -1]]
                    [:float64 [1.5 nil -0.25]]
                    [:boolean [true nil false]]
                    [:date [0 nil 19000]]
                    [:timestamp [1 nil 2]]
                    [:string ["a" nil ""]]]]
      (let [cv (col/from-objects t (object-array xs))]
        (is (= xs (values cv)) (str t))
        (is (= 1 (col/null-count cv))))))
  (testing "dictionary encoding: forced, automatic when repetitive, disabled"
    (let [xs (object-array (take 40 (cycle ["x" "y" nil])))]
      (is (col/dictionary-encoded? (col/from-objects :string (object-array ["a" "b"]) true)))
      (is (col/dictionary-encoded? (col/from-objects :string xs :auto)))
      (is (not (col/dictionary-encoded? (col/from-objects :string xs false))))
      (is (= (vec xs) (values (col/from-objects :string xs true))))
      (is (not (col/dictionary-encoded?
                (col/from-objects :string (object-array (map str (range 40))) :auto)))))))

(def columns [(table/->Column "id" :int64) (table/->Column "s" :string)])
(def data [(object-array [3 1 nil 2 1]) (object-array ["c" "a" "x" nil "a"])])

(deftest layouts
  (doseq [layout [:row :column]]
    (let [t (table/make-table "t" columns data 5 {:layout layout})]
      (is (= layout (:layout t)))
      (is (= [3 1 nil 2 1] (vec (table/column-array t 0))))
      (is (= ["c" "a" "x" nil "a"] (vec (table/column-array t 1)))))))

(deftest statistics
  (let [t (stats/with-stats (table/make-table "t" columns data 5))]
    (is (= {:null-count 1 :distinct-count 3 :min 1 :max 3} (stats/column-stats t 0)))
    (is (= {:null-count 1 :distinct-count 3 :min "a" :max "x"} (stats/column-stats t 1))))
  (testing "approximate distinct counts of large columns stay within 10%"
    (let [n 200000
          t (table/make-table "big" [(table/->Column "x" :int64)] [(object-array (range n))] n)
          d (:distinct-count (stats/column-stats t 0))]
      (is (< (Math/abs (- d n)) (* 0.1 n))))))

(defn- range-bound [value inclusive?]
  {:cmp (v/comparator-fn :int64 :int64 :int64) :value value :inclusive? inclusive?})

(deftest index-lookups
  (let [t (table/make-table "t" columns data 5)
        h (index/build t "h" 0 :hash)
        b (index/build t "b" 0 :btree)]
    (testing "hash lookups never return NULL rows"
      (is (= [1 4] (vec (index/lookup-equal h [1]))))
      (is (= [0 1 4] (vec (index/lookup-equal h [3 1 99])))))
    (testing "ordered lookups: ranges, open ends, empty ranges"
      (is (= [0 3] (vec (index/lookup-ranges b [{:lowers [(range-bound 2 true)] :uppers []}]))))
      (is (= [1 4] (vec (index/lookup-ranges b [{:lowers [] :uppers [(range-bound 2 false)]}]))))
      (is (= [] (vec (index/lookup-ranges b [{:lowers [(range-bound 3 false)] :uppers []}]))))
      (is (= [1 3 4] (vec (index/lookup-ranges b [{:lowers [(range-bound 1 true)] :uppers [(range-bound 2 true)]}])))))
    (is (= 3 (index/distinct-count h)))
    (is (= [1 3] [(index/smallest-key b) (index/largest-key b)]))))
