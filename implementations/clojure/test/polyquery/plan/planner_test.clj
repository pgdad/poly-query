(ns polyquery.plan.planner-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.plan.physical :as physical]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.test-util :refer [csv-catalog]]))

(def cat0 (csv-catalog {"a" "id,x\n1,10\n" "b" "id,a_id,y\n1,1,5\n"}))

(defn- plan
  ([sql] (plan sql {}))
  ([sql opts]
   (physical/plan-query (:query (analyzer/analyze-statement cat0 (parser/parse-statement sql) {})) opts)))

(defn- nodes [p]
  (tree-seq map? (fn [n] (keep n [:input :left :right])) p))

(defn- ops [p] (set (map :op (nodes p))))

(deftest join-algorithm-selection
  (testing "equality conjuncts between the inputs give a hash join"
    (let [j (first (filter #(= :hash-join (:op %)) (nodes (plan "SELECT * FROM a JOIN b ON b.a_id = a.id")))) ]
      (is (= :inner (:join-type j)))
      (is (= 1 (count (:left-keys j))))
      (is (= {:node :column :index 1} (select-keys (:expr (first (:right-keys j))) [:node :index])))))
  (testing "WHERE equalities over a comma join become hash join keys"
    (is (contains? (ops (plan "SELECT * FROM a, b WHERE a.id = b.a_id")) :hash-join)))
  (testing "non-equi conditions use nested loops"
    (is (contains? (ops (plan "SELECT * FROM a JOIN b ON a.id < b.a_id")) :nested-loop-join)))
  (testing "the join option can force nested loops"
    (is (contains? (ops (plan "SELECT * FROM a JOIN b ON a.id = b.a_id" {:join "nested_loop"}))
                   :nested-loop-join))))

(deftest predicate-pushdown
  (let [p (plan "SELECT * FROM a JOIN b ON a.id = b.a_id WHERE a.x > 1 AND b.y < 3")
        filters (filter #(= :filter (:op %)) (nodes p))]
    (is (= 2 (count filters)))
    (is (every? #(= :table-scan (:op (:input %))) filters)))
  (testing "WHERE conjuncts on the NULL-padded side of a LEFT JOIN stay above it"
    (let [p (plan "SELECT * FROM a LEFT JOIN b ON a.id = b.a_id WHERE b.y IS NULL")]
      (is (= :hash-join (:op (:input (first (filter #(= :filter (:op %)) (nodes p))))))))))

(deftest correlated-lookup
  (is (contains? (ops (-> (plan "SELECT (SELECT COUNT(*) FROM b WHERE b.a_id = a.id) FROM a")
                          :exprs first :plan))
                 :lookup-scan)))
