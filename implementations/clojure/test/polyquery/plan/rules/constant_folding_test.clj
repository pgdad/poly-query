(ns polyquery.plan.rules.constant-folding-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.plan.plan-util :refer [find-op logical-plan]]
            [polyquery.plan.rules.constant-folding :as cf]))

(defn- folded [sql] (cf/fold-constants (logical-plan sql)))

(deftest literal-only-expressions
  (testing "arithmetic, functions and CASE over literals become literals"
    (is (= [{:node :literal :type :int64 :value 7}]
           (:exprs (find-op (folded "SELECT 1 + 2 * 3 FROM a") :project))))
    (is (= [:literal :literal]
           (mapv :node (:exprs (find-op (folded "SELECT ABS(-4), CASE WHEN 1 = 1 THEN 'a' END") :project))))))
  (testing "expressions over columns are kept, their constant parts folded"
    (let [[e] (:exprs (find-op (folded "SELECT x + (2 * 3) FROM a") :project))]
      (is (= :arith (:node e)))
      (is (= {:node :literal :type :int64 :value 6} (:right e)))))
  (testing "an expression whose evaluation fails is left for execution"
    (is (= :compare (:node (:predicate (find-op (folded "SELECT x FROM a WHERE 1 / 0 = 1") :filter)))))))

(deftest predicate-simplification
  (testing "TRUE conjuncts disappear, a TRUE filter is removed"
    (is (= "(x > 1)" (polyquery.sql.bound/->sql
                      (:predicate (find-op (folded "SELECT x FROM a WHERE 1 = 1 AND x > 1") :filter)))))
    (is (nil? (find-op (folded "SELECT x FROM a WHERE 2 > 1") :filter))))
  (testing "double negation and FALSE disjuncts"
    (is (= "(x = 3)" (polyquery.sql.bound/->sql
                      (:predicate (find-op (folded "SELECT x FROM a WHERE NOT NOT (x = 3) OR 1 = 0") :filter))))))
  (testing "a failing operand of AND FALSE is still evaluated"
    (is (= :and (:node (:predicate (find-op (folded "SELECT x FROM a WHERE x / 0 = 1 AND FALSE") :filter)))))))

(deftest nested-query-blocks
  (testing "derived tables and UNION ALL branches are folded too"
    (let [p (folded "SELECT v FROM (SELECT 1 + 1 AS v FROM a) d UNION ALL SELECT 2 * 2")
          inner (find-op (:input (find-op (first (:inputs p)) :derived)) :project)]
      (is (= {:node :literal :type :int64 :value 2} (first (:exprs inner))))
      (is (= {:node :literal :type :int64 :value 4} (first (:exprs (second (:inputs p)))))))))
