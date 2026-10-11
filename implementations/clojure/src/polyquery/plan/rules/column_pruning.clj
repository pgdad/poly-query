(ns polyquery.plan.rules.column-pruning
  "Optimizer rule `column-pruning` (projection pushdown,
  spec/storage/indexes-and-planning.md §3.2): restricts every scan of a
  logical plan to the table columns the query references.

  Rows keep their full width (expressions address FROM-row positions), but a
  scan only reads and fills the referenced columns; the others stay NULL and
  are never looked at.

  A node's required input columns are the columns its own expressions use
  plus, for pass-through nodes (filter, join), the columns required from it.
  Expressions containing subqueries also require the columns of this row
  that correlated references inside the subqueries read (outer-column nodes
  of the subquery's correlation cell, at any nesting depth)."
  (:require [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(defn- outer-refs
  "Row indices read through correlation cell `cell` anywhere inside x (a
  bound query or part of one). Tables (records) are not descended into."
  [x cell]
  (into #{}
        (keep #(when (and (map? %) (= :outer-column (:node %)) (= cell (:cell %))) (:index %)))
        (tree-seq #(and (coll? %) (not (record? %)))
                  #(if (map? %) (vals %) (seq %))
                  x)))

(defn expr-columns
  "Indices of the row an expression is evaluated on that it reads."
  [e]
  (if (nil? e)
    #{}
    (into (b/column-indices e)
          (mapcat #(outer-refs (:query %) (:cell %)))
          (filter #(= :subquery (:node %)) (b/nodes e)))))

(defn- all-columns [node] (set (range (:width node))))

(defn- null-literal
  "Replacement of an output expression nobody reads."
  [e]
  {:node :literal :type (:type e) :value nil})

(defn- unused-aggregate
  "Replacement of an aggregate nobody reads (needs no argument column)."
  [spec]
  {:fn :count-star :type (:type spec) :distinct? false})

(declare prune)

(defn prune-columns
  "The rule: prunes the scans of a query plan of which the outputs
  :required-outputs of its root (default: all) are needed."
  [plan]
  (prune plan (or (:required-outputs plan) (all-columns plan))))

(defn prune
  "Prunes the scans below node, of which the output columns `required` (a
  set of indices) are needed. Output expressions and aggregates that are not
  required are replaced by constants, so that the columns only they read are
  not scanned."
  [node required]
  (case (:op node)
    :scan (assoc node :columns (vec (sort (filter #(< (long %) (long (:width node))) required))))
    :values node
    :derived (update node :input prune required)
    :filter (update node :input prune (into required (expr-columns (:predicate node))))
    :join (let [lw (long (:width (:left node)))
                cols (into required (expr-columns (:condition node)))]
            (assoc node
                   :left (prune (:left node) (set (filter #(< (long %) lw) cols)))
                   :right (prune (:right node) (set (keep #(when (>= (long %) lw) (- (long %) lw)) cols)))))
    :aggregate (let [nk (count (:group-keys node))
                     aggs (vec (map-indexed (fn [^long j a] (if (contains? required (+ nk j)) a (unused-aggregate a)))
                                            (:aggregates node)))]
                 (-> node
                     (assoc :aggregates aggs)
                     (update :input prune (into (into #{} (mapcat expr-columns) (:group-keys node))
                                                (mapcat (comp expr-columns :arg))
                                                aggs))))
    :project (let [exprs (vec (map-indexed (fn [i e] (if (contains? required i) e (null-literal e)))
                                           (:exprs node)))]
               (-> node
                   (assoc :exprs exprs)
                   (update :input prune (into #{} (mapcat expr-columns) exprs))))
    :distinct (update node :input #(prune % (all-columns %)))
    :sort (update node :input prune (into required (map :index) (:keys node)))
    :limit (update node :input prune required)
    ;; branch outputs are the union's columns, position for position
    :union-all (update node :inputs (fn [ins] (mapv #(prune % required) ins)))))
