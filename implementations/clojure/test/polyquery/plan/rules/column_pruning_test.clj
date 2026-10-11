(ns polyquery.plan.rules.column-pruning-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.plan.optimizer :as optimizer]
            [polyquery.plan.plan-util :refer [find-op logical-plan nodes subquery-plans]]
            [polyquery.plan.rules.column-pruning :as cp]))

(defn- pruned [sql] (optimizer/apply-rule cp/prune-columns (logical-plan sql)))

(defn- scan-columns [plan]
  (into {} (for [n (nodes plan) :when (= :scan (:op n))] [(:name (:table n)) (:columns n)])))

(deftest scans-read-referenced-columns
  (is (= {"a" [0 1]} (scan-columns (logical-plan "SELECT x FROM a"))))
  (is (= {"a" [1]} (scan-columns (pruned "SELECT x FROM a"))))
  (is (= {"a" [0 1] "b" [1 2]} (scan-columns (pruned "SELECT a.x, b.y FROM a JOIN b ON b.a_id = a.id"))))
  (is (= {"a" [0]} (scan-columns (pruned "SELECT COUNT(*) FROM a WHERE id > 1")))))

(deftest unread-outputs-are-not-computed
  (let [p (pruned "SELECT v FROM (SELECT x AS v, id / 0 AS w, COUNT(*) AS n FROM a GROUP BY x, id) d")
        inner (find-op (:input (find-op p :derived)) :project)]
    (testing "outputs nobody reads become NULL literals"
      (is (= :column (:node (first (:exprs inner)))))
      (is (= [{:node :literal :type :int64 :value nil} {:node :literal :type :int64 :value nil}]
             (rest (:exprs inner)))))
    (testing "and the scan below reads only what remains"
      (is (= {"a" [0 1]} (scan-columns p))))))

(deftest unread-aggregates
  (let [p (pruned "SELECT k FROM (SELECT x AS k, SUM(id) AS s FROM a GROUP BY x) d")]
    (is (= [:count-star] (mapv :fn (:aggregates (find-op (:input (find-op p :derived)) :aggregate)))))
    (is (= {"a" [1]} (scan-columns p)))))

(deftest subqueries
  (testing "an EXISTS subquery reads only the columns its predicates need"
    (let [[sub] (subquery-plans (pruned "SELECT x FROM a WHERE EXISTS (SELECT y FROM b WHERE b.a_id = a.id)"))]
      (is (= {"b" [1]} (scan-columns sub)))))
  (testing "columns read by correlated references are kept in the outer scan"
    (is (= {"a" [0 1]} (scan-columns (pruned "SELECT x FROM a WHERE EXISTS (SELECT 1 FROM b WHERE b.a_id = a.id)"))))))

(deftest idempotent
  (let [p (pruned "SELECT v FROM (SELECT x AS v, id AS w FROM a) d")]
    (is (= p (optimizer/apply-rule cp/prune-columns p)))))
