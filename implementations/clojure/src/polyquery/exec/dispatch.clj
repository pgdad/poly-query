(ns polyquery.exec.dispatch
  "Chooses the implementation of every plan node from the execution
  environment (spec/phases/phase-5.md):
    * nodes the planner marked for parallel execution (:partitions) run
      partitioned (polyquery.exec.parallel);
    * in `mode: vectorized` filters, projections and hash aggregation run on
      column batches, hash joins probe batches (polyquery.exec.vjoin),
      sorts use primitive key columns (polyquery.exec.vectorized);
    * everything else — and every node in `mode: row`, the unoptimized
      baseline — runs row at a time (polyquery.exec.operators,
      polyquery.exec.join).
  `build` is installed as the environment's :build, so operators build
  their inputs (and subquery plans) through it.

  Shared subqueries: in vectorized mode, the input of a subquery scan (a
  CTE or derived table) that occurs more than once in a query, is
  uncorrelated and deterministic, and ends in a blocking operator
  (aggregation, sort, DISTINCT, LIMIT — it is materialized anyway) is
  executed once per query execution and its rows reused
  (polyquery.exec.operators/shared-input). Row mode, which is also the
  re-execution after runtime errors, evaluates every reference: a shared
  result is computed in full where a single reference might have stopped
  early."
  (:require [polyquery.exec.join]
            [polyquery.exec.operators :as ops]
            [polyquery.exec.parallel :as parallel]
            [polyquery.exec.vectorized :as vectorized]
            [polyquery.exec.vjoin]))

(set! *warn-on-reflection* true)

(defn- plan-nodes
  "Every map in a physical plan — plan nodes and expressions, including
  subquery plans — not descending into tables and indexes (records)."
  [plan]
  (filter map? (tree-seq #(or (and (map? %) (not (record? %))) (vector? %) (seq? %))
                         #(if (map? %) (vals %) %)
                         plan)))

(defn- materializing?
  "True if the rows of plan come from a blocking operator below filters
  and projections."
  [plan]
  (case (:op plan)
    (:filter :project :subquery-scan) (recur (:input plan))
    (:hash-aggregate :sort :top-n :distinct :limit) true
    false))

(defn- shareable?
  [plan]
  (and (materializing? plan)
       (not-any? #(or (= :outer-column (:node %)) (= "PQ_SLEEP" (:fn %))) (plan-nodes plan))))

(defn shared-subplans
  "Inputs of subquery scans that occur more than once in the plan and can be
  executed once for all of them (see the namespace doc)."
  [plan]
  (->> (plan-nodes plan)
       (keep #(when (= :subquery-scan (:op %)) (:input %)))
       frequencies
       (keep (fn [[p n]] (when (and (> (long n) 1) (shareable? p)) p)))
       set))

(def ^:private vectorized-ops #{:filter :project :hash-aggregate :sort :hash-join})

(defn build
  "Compiles a physical plan node into a re-reducible of rows."
  [plan env]
  (cond
    (and (:partitions plan) (> (long (:partitions plan)) 1)) (parallel/build plan env)
    (and (= :vectorized (:mode env)) (vectorized-ops (:op plan))) (vectorized/build-rows plan env)
    :else (ops/build plan env)))

(defn environment
  "Execution environment of a query: opts :mode (:row | :vectorized),
  :max-join-rows, :native (the native kernel library used by vectorized
  operators, polyquery.native.ffi, or nil), :plan (the physical plan, for
  shared subqueries); qctx the QueryContext."
  [qctx opts]
  {:ctx qctx
   :shared (when (= :vectorized (:mode opts))
             (let [plans (shared-subplans (:plan opts))]
               (when (seq plans)
                 {:plans plans :cache (java.util.concurrent.ConcurrentHashMap.)})))
   :cells (atom {})
   :build build
   :mode (:mode opts :row)
   :max-join-rows (:max-join-rows opts)
   :native (when (= :vectorized (:mode opts)) (:native opts))})
