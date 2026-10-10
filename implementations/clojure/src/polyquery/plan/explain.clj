(ns polyquery.plan.explain
  "EXPLAIN output (spec/storage/indexes-and-planning.md §4): renders a
  physical plan as a tree of JSON-ready maps with `op` and `children`."
  (:require [clojure.string :as str]
            [polyquery.sql.bound :as b]
            [polyquery.types :as t]))

(set! *warn-on-reflection* true)

(declare plan->json)

(defn- subplans
  "EXPLAIN trees of the subqueries in the given expressions."
  [exprs]
  (vec (for [e exprs :when e
             x (b/nodes e) :when (and (= :subquery (:node x)) (:plan x))]
         (assoc (plan->json (:plan x)) "subquery" (name (:kind x))))))

(defn- join-type [k] (str/upper-case (name k)))

(defn- node-exprs
  [node]
  (case (:op node)
    :filter [(:predicate node)]
    :hash-join (concat (map :expr (:left-keys node)) (map :expr (:right-keys node)) [(:residual node)])
    :nested-loop-join [(:condition node)]
    :hash-aggregate (concat (:group-keys node) (keep :arg (:aggregates node)))
    :project (:exprs node)
    :limit [(:limit node) (:offset node)]
    []))

(defn- props
  [node]
  (case (:op node)
    :values {"op" "Values" "rows" (count (:rows node))}
    :table-scan {"op" "TableScan" "table" (:name (:table node)) "alias" (:alias node)
                 "columns" (mapv #(:name (nth (:columns (:table node)) %)) (:columns node))}
    :subquery-scan {"op" "SubqueryScan" "alias" (:alias node)}
    :filter {"op" "Filter" "predicate" (b/->sql (:predicate node))}
    :hash-join (cond-> {"op" "HashJoin" "join_type" (join-type (:join-type node))
                        "build" "right"
                        "keys" (mapv (fn [l r] (str (b/->sql (:expr l)) " = " (b/->sql (:expr r))))
                                     (:left-keys node) (:right-keys node))}
                 (:residual node) (assoc "residual" (b/->sql (:residual node))))
    :nested-loop-join (cond-> {"op" "NestedLoopJoin" "join_type" (join-type (:join-type node))}
                        (:condition node) (assoc "condition" (b/->sql (:condition node))))
    :hash-aggregate {"op" "Aggregate" "algorithm" "hash"
                     "group_by" (mapv b/->sql (:group-keys node))
                     "aggregates" (mapv b/aggregate->sql (:aggregates node))}
    :project {"op" "Project" "columns" (vec (:names node))
              "exprs" (mapv b/->sql (:exprs node))}
    :distinct {"op" "Distinct"}
    :sort {"op" "Sort" "keys" (mapv (fn [k] (str "#" (:index k) (if (:desc? k) " DESC" " ASC")
                                                  (if (:nulls-first? k) " NULLS FIRST" " NULLS LAST")))
                                    (:keys node))}
    :limit (cond-> {"op" "Limit"}
             (:limit node) (assoc "limit" (b/->sql (:limit node)))
             (:offset node) (assoc "offset" (b/->sql (:offset node))))))

(defn- children [node]
  (case (:op node)
    (:hash-join :nested-loop-join) [(:left node) (:right node)]
    (if (:input node) [(:input node)] [])))

(defn plan->json
  [node]
  (let [subs (subplans (node-exprs node))]
    (cond-> (assoc (props node) "children" (mapv plan->json (children node)))
      (seq subs) (assoc "subqueries" subs)
      (:columns node) (assoc "output" (mapv (fn [c] (str (:name c) " " (t/type-name (:type c))))
                                            (filter map? (:columns node)))))))
