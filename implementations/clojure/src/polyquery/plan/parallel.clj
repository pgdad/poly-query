(ns polyquery.plan.parallel
  "Parallelization of physical plans for `threads` > 1 (spec/phases/
  phase-5.md, executed by polyquery.exec.parallel).

  A *partitionable pipeline* is a table scan below filters, projections,
  derived tables and the probe side of hash joins whose expressions contain
  no subqueries and no correlated references: it can be executed
  independently on disjoint row ranges of the scanned table.

    * a hash aggregation, sort or top-N over a partitionable pipeline gets
      :partitions N (partial results per partition, merged);
    * any other maximal partitionable pipeline is wrapped in a Gather node
      (parallel scan, rows streamed in table order) — except below a LIMIT
      without an intervening blocking operator, where reading ahead would
      only waste work;
    * the build sides of hash joins and the materialized inputs of
      sort-merge and nested-loop joins are parallelized independently.
  Plans are left unchanged for threads = 1."
  (:require [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(defn- safe?
  "True when e can be evaluated by any thread on its own (no subqueries,
  no correlated references)."
  [e]
  (or (nil? e) (not-any? #(#{:subquery :outer-column} (:node %)) (b/nodes e))))

(defn- probe-side [node] (if (= :left (:build node)) :right :left))
(defn- build-side [node] (if (= :left (:build node)) :left :right))

(defn partitionable?
  "True when node is a partitionable pipeline (see the namespace doc)."
  [node]
  (case (:op node)
    :table-scan true
    :filter (and (safe? (:predicate node)) (partitionable? (:input node)))
    :project (and (every? safe? (:exprs node)) (partitionable? (:input node)))
    :subquery-scan (partitionable? (:input node))
    :hash-join (and (every? (comp safe? :expr) (concat (:left-keys node) (:right-keys node)))
                    (safe? (:residual node))
                    (partitionable? ((probe-side node) node)))
    false))

(defn- aggregate-safe? [node]
  (and (every? safe? (:group-keys node)) (every? (comp safe? :arg) (:aggregates node))))

(declare par)

(defn- par-builds
  "Parallelizes the build sides of the joins inside a partitionable pipeline."
  [node threads]
  (case (:op node)
    :table-scan node
    (:filter :project :subquery-scan) (update node :input par-builds threads)
    :hash-join (-> node
                   (update (build-side node) par threads false)
                   (update (probe-side node) par-builds threads))))

(defn- par
  "Parallelizes node; limited? is true below a LIMIT with no blocking
  operator in between."
  [node threads limited?]
  (let [op (:op node)]
    (cond
      (and (= :hash-aggregate op) (aggregate-safe? node) (partitionable? (:input node)))
      (-> node (assoc :partitions threads) (update :input par-builds threads))

      (and (#{:sort :top-n} op) (partitionable? (:input node)))
      (-> node (assoc :partitions threads) (update :input par-builds threads))

      (partitionable? node)
      (let [inner (par-builds node threads)]
        (if limited? inner {:op :gather :input inner :partitions threads}))

      :else
      (case op
        :limit (update node :input par threads true)
        (:hash-aggregate :sort :top-n) (update node :input par threads false)
        (:filter :project :subquery-scan :distinct) (update node :input par threads limited?)
        :hash-join (-> node
                       (update (build-side node) par threads false)
                       (update (probe-side node) par threads limited?))
        :merge-join (-> node (update :left par threads false) (update :right par threads false))
        :nested-loop-join (-> node
                              (update :left par threads limited?)
                              (update :right par threads false))
        node))))

(defn parallelize
  "Marks the parallel parts of a physical plan for `threads` workers."
  [plan threads]
  (if (<= (long threads) 1) plan (par plan (long threads) false)))
