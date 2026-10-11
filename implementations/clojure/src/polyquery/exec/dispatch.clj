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
  their inputs (and subquery plans) through it."
  (:require [polyquery.exec.join]
            [polyquery.exec.operators :as ops]
            [polyquery.exec.parallel :as parallel]
            [polyquery.exec.vectorized :as vectorized]
            [polyquery.exec.vjoin]))

(set! *warn-on-reflection* true)

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
  operators, polyquery.native.ffi, or nil); qctx the QueryContext."
  [qctx opts]
  {:ctx qctx
   :cells (atom {})
   :build build
   :mode (:mode opts :row)
   :max-join-rows (:max-join-rows opts)
   :native (when (= :vectorized (:mode opts)) (:native opts))})
