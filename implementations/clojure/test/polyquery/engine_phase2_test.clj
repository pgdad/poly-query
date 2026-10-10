(ns polyquery.engine-phase2-test
  "End-to-end tests of the Phase 2 SQL features through the engine pipeline."
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.engine :as engine]
            [polyquery.test-util :refer [csv-catalog error-code]]))

(def cat0
  (csv-catalog
   {"emp" "id,name,dept,salary,boss\n1,Ann,eng,100.50,\n2,Bo,eng,80.00,1\n3,Cy,ops,70.25,1\n4,Di,,60.00,3\n"
    "dept" "code,title\neng,Engineering\nops,Operations\nhr,Human Resources\n"}))

(defn- run [sql] (engine/run-query cat0 sql {}))
(defn- rows [sql] (mapv vec (:rows (run sql))))
(defn- columns [sql] (mapv #(get % "type") (:columns (run sql))))

(deftest grouping
  (is (= [[nil 1 60.0] ["eng" 2 180.5] ["ops" 1 70.25]]
         (rows "SELECT dept, COUNT(*), SUM(salary) FROM emp GROUP BY dept ORDER BY dept")))
  (is (= [["eng"]] (rows "SELECT dept FROM emp GROUP BY dept HAVING COUNT(*) > 1")))
  (is (= [[2]] (rows "SELECT COUNT(DISTINCT dept) FROM emp")))
  (is (= [[nil] ["eng"] ["ops"]] (rows "SELECT DISTINCT dept FROM emp ORDER BY 1")))
  (is (= "SEMANTIC_ERROR" (error-code (run "SELECT name FROM emp GROUP BY dept")))))

(deftest joins
  (is (= [["Ann" "Engineering"] ["Bo" "Engineering"] ["Cy" "Operations"]]
         (rows "SELECT e.name, d.title FROM emp e JOIN dept d ON d.code = e.dept ORDER BY 1")))
  (is (= [["Ann" "Engineering"] ["Bo" "Engineering"] ["Cy" "Operations"] ["Di" nil]]
         (rows "SELECT e.name, d.title FROM emp e LEFT JOIN dept d ON d.code = e.dept ORDER BY 1")))
  (is (= [[12]] (rows "SELECT COUNT(*) FROM emp, dept")))
  (testing "self join with a non-equi condition"
    (is (= [["Bo" "Ann"] ["Cy" "Ann"] ["Di" "Cy"]]
           (rows "SELECT e.name, b.name FROM emp e JOIN emp b ON e.boss = b.id ORDER BY 1"))))
  (is (= "SEMANTIC_ERROR" (error-code (run "SELECT id FROM emp a JOIN emp b ON a.id = b.id")))))

(deftest subqueries-and-ctes
  (is (= [["Ann"]] (rows "SELECT name FROM emp WHERE salary = (SELECT MAX(salary) FROM emp)")))
  (is (= [["Human Resources"]]
         (rows "SELECT title FROM dept WHERE code NOT IN (SELECT dept FROM emp WHERE dept IS NOT NULL)")))
  (is (= [["Ann" 2] ["Bo" 0] ["Cy" 1] ["Di" 0]]
         (rows "SELECT e.name, (SELECT COUNT(*) FROM emp r WHERE r.boss = e.id) FROM emp e ORDER BY 1")))
  (is (= [[3]] (rows "WITH big AS (SELECT * FROM emp WHERE salary > 65) SELECT COUNT(*) FROM big")))
  (is (= "SUBQUERY_CARDINALITY" (error-code (run "SELECT (SELECT id FROM emp)")))))

(deftest functions-and-typing
  (is (= [["DECIMAL(18,1)" "INT64" "STRING" "FLOAT64"]]
         [(columns "SELECT COALESCE(1, 2.5), ROUND(15, -1), CONCAT('a', 1), POWER(2, 3)")]))
  (is (= [["3" 20 "a1" 8.0]] (rows "SELECT ROUND(2.5), ROUND(15, -1), CONCAT('a', NULL, 1), POWER(2, 3)")))
  (is (= [[true nil false]] (rows "SELECT 2 IN (1, 2), 3 IN (1, NULL), 'b' LIKE 'a%'"))))

(deftest explain
  (let [{:keys [columns rows]} (run "EXPLAIN SELECT * FROM emp WHERE id = 1")]
    (is (= [{"name" "plan" "type" "STRING"}] columns))
    (is (re-find #"TableScan" (ffirst rows)))))
