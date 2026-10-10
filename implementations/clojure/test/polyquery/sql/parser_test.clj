(ns polyquery.sql.parser-test
  (:require [clojure.test :refer [deftest is testing]]
            [polyquery.sql.parser :as parser]
            [polyquery.test-util :refer [error-code]]))

(defn- strip [x]
  (cond (map? x) (into {} (keep (fn [[k v]] (when-not (#{:pos :parenthesized?} k) [k (strip v)]))) x)
        (vector? x) (mapv strip x)
        :else x))

(defn- expr [s] (strip (-> (parser/parse-statement (str "SELECT " s)) :query :select :items first :expr)))

(deftest precedence
  (is (= {:node :binary :op "+" :left {:node :literal :kind :number :text "1"}
          :right {:node :binary :op "*" :left {:node :literal :kind :number :text "2"}
                  :right {:node :literal :kind :number :text "3"}}}
         (expr "1 + 2 * 3")))
  (testing "unary minus folds into numeric literals"
    (is (= {:node :literal :kind :number :text "-9223372036854775808"} (expr "-9223372036854775808"))))
  (testing "NOT binds looser than comparison"
    (is (= :not (:node (expr "NOT a = b"))))
    (is (= :binary (:node (:arg (expr "NOT a = b"))))))
  (testing "|| between + and comparison"
    (is (= "=" (:op (expr "a || b = c"))))
    (is (= "||" (:op (expr "a || b + c"))))))

(deftest query-structure
  (let [q (:query (parser/parse-statement
                   "SELECT p.*, x AS y, z w FROM people p WHERE a ORDER BY 1 DESC NULLS FIRST LIMIT 2 OFFSET 3;"))]
    (is (= [:star :expr :expr] (mapv :kind (-> q :select :items))))
    (is (= ["y" "w"] (keep :alias (-> q :select :items))))
    (is (= {:node :table :name "people" :alias "p"} (strip (-> q :select :from))))
    (is (= [{:desc? true :nulls :first}] (mapv #(select-keys % [:desc? :nulls]) (:order-by q))))
    (is (some? (:limit q)))
    (is (some? (:offset q)))))

(deftest parse-errors
  (doseq [sql ["SELEC 1" "SELECT 1 = 1 = 1" "SELECT 1; SELECT 2" "SELECT (1" "SELECT 1 +"
               "SELECT a FROM t LIMIT 1 LIMIT 2" "SELECT a, FROM t" "SELECT a < b IS NULL"
               "SELECT COUNT(*, a) FROM t" "SELECT CAST(1 AS)" "SELECT select FROM t"]]
    (testing sql (is (= "PARSE_ERROR" (error-code (parser/parse-statement sql)))))))

(deftest unsupported-syntax
  (is (= "UNSUPPORTED" (error-code (parser/parse-statement "SELECT 1 UNION SELECT 2"))))
  (is (= "UNSUPPORTED" (error-code (parser/parse-statement "SELECT * FROM a RIGHT JOIN b ON x")))))
