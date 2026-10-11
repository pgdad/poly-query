(ns polyquery.plan.optimizer-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.plan.optimizer :as optimizer]
            [polyquery.plan.plan-util :refer [logical-plan nodes subquery-plans]]))

(def ^:private sql
  "SELECT a.x FROM a, b WHERE a.id = b.a_id AND 1 + 1 = 2 AND b.y IN (SELECT y FROM b WHERE 2 > 1)")

(deftest named-rules
  (is (= ["constant-folding" "predicate-pushdown" "join-reordering" "column-pruning"]
         (mapv :name optimizer/rules)))
  (is (every? fn? (map :rewrite optimizer/rules))))

(deftest optimize-false-applies-no-rule
  (let [p (logical-plan sql)]
    (is (identical? p (optimizer/optimize p {:optimize false})))
    (is (not= p (optimizer/optimize p {})))))

(deftest optimize-applies-every-rule-in-order
  (let [p (logical-plan sql)]
    (is (= (reduce #(optimizer/apply-rule (:rewrite %2) %1) p optimizer/rules)
           (optimizer/optimize p {:optimize true})))))

(deftest rules-reach-subquery-plans
  (let [folded (optimizer/apply-rule (optimizer/rule "constant-folding") (logical-plan sql))
        [sub] (subquery-plans folded)]
    (testing "the subquery's WHERE 2 > 1 is folded to TRUE and dropped"
      (is (not-any? #(= :filter (:op %)) (nodes sub))))))
