(ns polyquery.plan.rules.join-reordering-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.plan.plan-util :refer [find-op logical-plan nodes]]
            [polyquery.plan.rules.join-reordering :as jr]
            [polyquery.plan.rules.predicate-pushdown :as pd]))

(defn- reordered [sql] (jr/reorder-joins (pd/pushdown (logical-plan sql))))

(defn- scan-order [plan]
  (keep #(when (= :scan (:op %)) (:name (:table %))) (nodes plan)))

(deftest greedy-left-deep-order
  (let [p (reordered "SELECT * FROM big, mid, small WHERE big.k = mid.id AND mid.k = small.id")
        restore (:input p)]
    (testing "the smallest relation first, then the connected ones by size"
      (is (= ["small" "mid" "big"] (scan-order p))))
    (testing "every join has its condition"
      (is (every? #(and (= :inner (:kind %)) (:condition %)) (filter #(= :join (:op %)) (nodes p)))))
    (testing "a projection restores the FROM column order"
      (is (= :project (:op restore)))
      (is (= [4 5 2 3 0 1] (mapv :index (:exprs restore))))
      (is (= 6 (:width restore))))))

(deftest left-alone
  (testing "two relations (the hash join builds on the smaller one anyway)"
    (is (= ["big" "small"] (scan-order (reordered "SELECT * FROM big, small WHERE big.k = small.id")))))
  (testing "clusters already in greedy order"
    (let [p (reordered "SELECT * FROM small, mid, big WHERE big.k = mid.id AND mid.k = small.id")]
      (is (= ["small" "mid" "big"] (scan-order p)))
      (is (= :join (:op (:input p))))))
  (testing "LEFT joins bound clusters"
    (is (= ["big" "mid" "small"]
           (scan-order (reordered "SELECT * FROM big LEFT JOIN mid ON big.k = mid.id LEFT JOIN small ON mid.k = small.id"))))))

(deftest inside-derived-tables
  (let [p (reordered "SELECT * FROM (SELECT big.id FROM big, mid, small WHERE big.k = mid.id AND mid.k = small.id) d")]
    (is (= ["small" "mid" "big"] (scan-order p)))
    (testing "the restoring projection sits below the derived table's own"
      (is (= :project (:op (:input (:input (find-op p :derived)))))))))
