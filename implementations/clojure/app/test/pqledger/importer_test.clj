(ns pqledger.importer-test
  (:require [clojure.test :refer [deftest is]]
            [pqledger.importer :as importer]))

(defn- rec [n merchant] {:line n :date :d :cents 100 :merchant merchant})

(deftest duplicates-keep-the-last-records
  (let [records [(rec 1 "A") (rec 2 "A") (rec 3 "B") (rec 4 "A")]]
    (is (= [1 2 3 4] (map :line (importer/select-new records {}))))
    (is (= [2 3 4] (map :line (importer/select-new records {[:d 100 "A"] 1}))))
    (is (= [4] (map :line (importer/select-new records {[:d 100 "A"] 2 [:d 100 "B"] 1}))))
    (is (= [] (map :line (importer/select-new records {[:d 100 "A"] 5 [:d 100 "B"] 1}))))))
