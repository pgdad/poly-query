(ns polyquery.plan.plan-util
  "Helpers of the planner tests: logical plans of SQL over a small catalog,
  plan node searches."
  (:require [polyquery.plan.logical :as logical]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.test-util :refer [csv-catalog]]))

(defn- rows [n f] (apply str (map f (range n))))

(def catalog
  "a(id, x), b(id, a_id, y) and three tables of different sizes:
  big(id, k) 60 rows, mid(id, k) 12 rows, small(id, k) 3 rows."
  (csv-catalog {"a" "id,x\n1,10\n2,20\n"
                "b" "id,a_id,y\n1,1,5\n2,1,6\n"
                "big" (str "id,k\n" (rows 60 #(str % "," (mod % 12) "\n")))
                "mid" (str "id,k\n" (rows 12 #(str % "," (mod % 3) "\n")))
                "small" (str "id,k\n" (rows 3 #(str % "," % "\n")))}))

(defn bound-query [sql]
  (:query (analyzer/analyze-statement catalog (parser/parse-statement sql) {})))

(defn logical-plan
  "The unoptimized logical plan of a SQL query."
  [sql]
  (logical/plan-query (bound-query sql)))

(defn nodes
  "All nodes of a logical or physical plan (not those of subquery plans)."
  [plan]
  (tree-seq map? (fn [n] (concat (keep n [:input :left :right]) (:inputs n))) plan))

(defn find-op [plan op] (first (filter #(= op (:op %)) (nodes plan))))

(defn ops [plan] (set (map :op (nodes plan))))

(defn subquery-plans
  "Logical plans of the subqueries in the expressions of plan's nodes."
  [plan]
  (for [n (nodes plan) e (logical/exprs n)
        x (tree-seq map? #(keep % [:left :right :arg]) e)
        :when (:logical x)]
    (:logical x)))

(defn col [i type] {:node :column :index i :type type :name (str "c" i)})
(defn lit [v type] {:node :literal :value v :type type})
(defn cmp [op l r] {:node :compare :op op :cmp-type (:type l) :type :boolean :left l :right r})
