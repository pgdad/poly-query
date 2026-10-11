(ns polyquery.plan.logical-test
  (:require [clojure.string :as str]
            [clojure.test :refer [deftest is testing]]
            [polyquery.plan.logical :as logical]
            [polyquery.plan.plan-util :refer [logical-plan nodes subquery-plans]]))

(deftest operator-tree
  (let [p (logical-plan (str "SELECT DISTINCT a.x, COUNT(*) FROM a JOIN b ON b.a_id = a.id WHERE a.x > 1 "
                             "GROUP BY a.x HAVING COUNT(*) > 1 ORDER BY 2 DESC LIMIT 3"))]
    (testing "operators from LIMIT down to the scans"
      (is (= [:limit :sort :distinct :project :filter :aggregate :filter :join :scan :scan]
             (mapv :op (nodes p)))))
    (testing "the join keeps its type and condition"
      (let [j (first (filter #(= :join (:op %)) (nodes p)))]
        (is (= :inner (:kind j)))
        (is (= :compare (:node (:condition j))))))
    (testing "the aggregate carries its keys and aggregate calls"
      (let [agg (first (filter #(= :aggregate (:op %)) (nodes p)))]
        (is (= 1 (count (:group-keys agg))))
        (is (= [:count-star] (mapv :fn (:aggregates agg))))))
    (testing "the root describes the result columns"
      (is (= ["x" "_col2"] (mapv :name (:columns p)))))))

(deftest subqueries-and-ctes
  (testing "subquery expressions carry their logical plan"
    (let [[sub] (subquery-plans (logical-plan "SELECT x FROM a WHERE x IN (SELECT y FROM b)"))]
      (is (= [:project :scan] (mapv :op (nodes sub))))
      (is (nil? (:required-outputs sub)))))
  (testing "EXISTS subqueries need none of their outputs"
    (is (= #{} (:required-outputs (first (subquery-plans (logical-plan "SELECT x FROM a WHERE EXISTS (SELECT y FROM b)")))))))
  (testing "CTE references and derived tables are :derived nodes"
    (let [p (logical-plan "WITH c AS (SELECT id FROM a) SELECT * FROM c, (SELECT y FROM b) d")]
      (is (= ["c" "d"] (mapv :alias (filter #(= :derived (:op %)) (nodes p)))))))
  (testing "UNION ALL"
    (is (= :union-all (:op (logical-plan "SELECT x FROM a UNION ALL SELECT y FROM b"))))))

(deftest debug-rendering
  (is (= (str/join "\n" ["Project x AS x"
                         "  Filter EXISTS (<subquery>)"
                         "    Scan a AS a columns=[0 1]"
                         "    subquery exists:"
                         "      Project y AS y"
                         "        Filter (a_id = outer.id)"
                         "          Scan b AS b columns=[0 1 2]"])
         (logical/format-plan (logical-plan "SELECT x FROM a WHERE EXISTS (SELECT y FROM b WHERE b.a_id = a.id)")))))
