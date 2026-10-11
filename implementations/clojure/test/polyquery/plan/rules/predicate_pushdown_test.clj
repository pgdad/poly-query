(ns polyquery.plan.rules.predicate-pushdown-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.plan.plan-util :refer [cmp col find-op lit logical-plan nodes]]
            [polyquery.plan.rules.predicate-pushdown :as pd]
            [polyquery.sql.bound :as b]))

(defn- pushed [sql] (pd/pushdown (logical-plan sql)))

(defn- filtered-scans
  "{table predicate-sql} of the filters directly above scans."
  [plan]
  (into {} (for [n (nodes plan) :when (and (= :filter (:op n)) (= :scan (:op (:input n))))]
             [(:name (:table (:input n))) (b/->sql (:predicate n))])))

(deftest into-join-inputs
  (let [p (pushed "SELECT * FROM a JOIN b ON a.id = b.a_id AND b.y > 5 WHERE a.x > 1")]
    (testing "single-table conjuncts of WHERE and ON filter the scans"
      (is (= {"a" "(x > 1)" "b" "(y > 5)"} (filtered-scans p))))
    (testing "nothing is left above the join"
      (is (= :join (:op (:input p))))
      (is (= "(id = a_id)" (b/->sql (:condition (:input p))))))))

(deftest where-equalities-become-join-conditions
  (let [j (find-op (pushed "SELECT * FROM a, b WHERE a.id = b.a_id") :join)]
    (is (= :inner (:kind j)))
    (is (= "(id = a_id)" (b/->sql (:condition j))))))

(deftest left-joins
  (let [p (pushed "SELECT * FROM a LEFT JOIN b ON a.id = b.a_id AND b.y > 5 WHERE b.y IS NULL AND a.x > 1")]
    (testing "WHERE conjuncts on the NULL-padded side stay above the join"
      (is (= :filter (:op (:input p))))
      (is (= "(y IS NULL)" (b/->sql (:predicate (:input p))))))
    (testing "the preserved side and ON conjuncts over the right side are pushed"
      (is (= {"a" "(x > 1)" "b" "(y > 5)"} (filtered-scans p))))))

(deftest correlated-conjuncts-stay
  (let [p (pushed "SELECT * FROM a, b WHERE a.id = b.a_id AND EXISTS (SELECT 1 FROM b c WHERE c.y = a.x)")]
    (is (= :filter (:op (:input p))))
    (is (= "EXISTS (<subquery>)" (b/->sql (:predicate (:input p)))))))

(deftest into-derived-tables
  (let [p (pushed "SELECT * FROM (SELECT a.x FROM a, b WHERE a.id = b.a_id AND b.y = 6) d")]
    (is (= {"b" "(y = 6)"} (filtered-scans p)))
    (is (= :inner (:kind (find-op p :join))))))

(deftest below-projections
  (let [scan (find-op (logical-plan "SELECT * FROM a") :scan)
        ;; Filter(#0 > 5) over Project(x, id) over Scan a(id, x)
        project {:op :project :input scan :exprs [(col 1 :int64) (col 0 :int64)] :names ["x" "id"] :width 2}
        plan {:op :filter :input project :predicate (cmp ">" (col 0 :int64) (lit 5 :int64)) :width 2}]
    (testing "a filter over a renaming projection moves below it, rewritten over its input"
      (let [p (pd/pushdown plan)]
        (is (= :project (:op p)))
        (is (= :filter (:op (:input p))))
        (is (= (cmp ">" (col 1 :int64) (lit 5 :int64)) (:predicate (:input p))))))
    (testing "a projection computing values is a barrier"
      (let [computing (assoc-in plan [:input :exprs 0]
                                {:node :arith :op "+" :type :int64 :left (col 1 :int64) :right (lit 1 :int64)})]
        (is (= computing (pd/pushdown computing)))))))
