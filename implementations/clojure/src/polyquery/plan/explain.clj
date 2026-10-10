(ns polyquery.plan.explain
  "EXPLAIN output (spec/storage/indexes-and-planning.md §4): renders a
  physical plan as a tree of JSON-ready maps with `op` and `children`."
  (:require [clojure.string :as str]
            [polyquery.sql.bound :as b]
            [polyquery.storage.index :as index]
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

(defn- column-names
  "Names of the table columns a scan reads."
  [node]
  (mapv #(:name (nth (:columns (:table node)) %)) (:columns node)))

(defn- node-exprs
  [node]
  (case (:op node)
    :filter [(:predicate node)]
    :lookup-scan (concat (map :expr (:keys node)) (map :probe (:keys node)) [(:residual node)])
    (:hash-join :merge-join) (concat (map :expr (:left-keys node)) (map :expr (:right-keys node))
                                     [(:residual node)])
    :nested-loop-join [(:key-condition node) (:condition node)]
    :hash-aggregate (concat (:group-keys node) (keep :arg (:aggregates node)))
    :project (:exprs node)
    (:limit :top-n) [(:limit node) (:offset node)]
    []))

(defn- join-keys [node]
  (mapv (fn [l r] (str (b/->sql (:expr l)) " = " (b/->sql (:expr r))))
        (:left-keys node) (:right-keys node)))

(defn- sort-keys [node]
  (mapv (fn [k] (str "#" (:index k) (if (:desc? k) " DESC" " ASC")
                     (if (:nulls-first? k) " NULLS FIRST" " NULLS LAST")))
        (:keys node)))

(defn- props
  [node]
  (case (:op node)
    :values {"op" "Values" "rows" (count (:rows node))}
    :table-scan (cond-> {"op" "TableScan" "table" (:name (:table node)) "alias" (:alias node)
                         "columns" (column-names node)
                         "layout" (name (:layout (:table node)))}
                  (seq (:skip node)) (assoc "row_groups" (count (:segments (:table node)))
                                            "skip_predicates" (mapv :sql (:skip node))))
    :index-scan {"op" "IndexScan" "table" (:name (:table node)) "alias" (:alias node)
                 "index" (:name (:index node)) "kind" (index/kind-name (:kind (:index node)))
                 "column" (:column (:index node))
                 "columns" (column-names node)
                 "lookup" (vec (distinct (map :sql (:predicates node))))}
    :subquery-scan {"op" "SubqueryScan" "alias" (:alias node)}
    :lookup-scan (cond-> {"op" "HashLookup"
                          "keys" (mapv (fn [k] (str (b/->sql (:expr k)) " = " (b/->sql (:probe k))))
                                       (:keys node))}
                   (:residual node) (assoc "residual" (b/->sql (:residual node))))
    :filter {"op" "Filter" "predicate" (b/->sql (:predicate node))}
    :hash-join (cond-> {"op" "HashJoin" "join_type" (join-type (:join-type node))
                        "build" (name (or (:build node) :right))
                        "keys" (join-keys node)}
                 (:residual node) (assoc "residual" (b/->sql (:residual node))))
    :merge-join (cond-> {"op" "MergeJoin" "join_type" (join-type (:join-type node))
                         "keys" (join-keys node)}
                  (:residual node) (assoc "residual" (b/->sql (:residual node))))
    :nested-loop-join (cond-> {"op" "NestedLoopJoin" "join_type" (join-type (:join-type node))}
                        (:key-condition node) (assoc "keys" (b/->sql (:key-condition node)))
                        (:condition node) (assoc "condition" (b/->sql (:condition node))))
    :hash-aggregate {"op" "Aggregate" "algorithm" "hash"
                     "group_by" (mapv b/->sql (:group-keys node))
                     "aggregates" (mapv b/aggregate->sql (:aggregates node))}
    :project {"op" "Project" "columns" (vec (:names node))
              "exprs" (mapv b/->sql (:exprs node))}
    :distinct {"op" "Distinct"}
    :sort {"op" "Sort" "keys" (sort-keys node)}
    :top-n (cond-> {"op" "TopN" "keys" (sort-keys node) "limit" (b/->sql (:limit node))}
             (:offset node) (assoc "offset" (b/->sql (:offset node))))
    :gather {"op" "Gather"}
    :limit (cond-> {"op" "Limit"}
             (:limit node) (assoc "limit" (b/->sql (:limit node)))
             (:offset node) (assoc "offset" (b/->sql (:offset node))))))

(defn- children [node]
  (case (:op node)
    :lookup-scan [(assoc node :op :table-scan)]
    (:hash-join :merge-join :nested-loop-join) [(:left node) (:right node)]
    (if (:input node) [(:input node)] [])))

(defn plan->json
  "EXPLAIN tree of a physical plan. The plans of subqueries evaluated by a
  node follow its input(s) among its children (marked with \"subquery\")."
  [node]
  (let [subs (subplans (node-exprs node))]
    (cond-> (assoc (props node) "children" (into (mapv plan->json (children node)) subs))
      (:partitions node) (assoc "partitions" (:partitions node))
      (and (:columns node) (not (#{:table-scan :index-scan} (:op node))))
      (assoc "output" (mapv (fn [c] (str (:name c) " " (t/type-name (:type c))))
                            (filter map? (:columns node)))))))
