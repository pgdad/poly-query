(ns polyquery.plan.planner
  "The planning pipeline of a bound query:
    logical plan (polyquery.plan.logical)
    → column requirements (the column-pruning rule)
    → logical optimizer (polyquery.plan.optimizer)
    → physical plan (polyquery.plan.physical).

  Column pruning is applied even when `optimize: false` disables the
  optimizer: scans materializing only referenced columns is mandatory
  (spec/storage/indexes-and-planning.md §3.2), and outputs nobody reads must
  never be evaluated, so that results do not depend on `optimize`. The
  optimizer re-applies the rule after the rules that restructure the plan."
  (:require [polyquery.plan.logical :as logical]
            [polyquery.plan.optimizer :as optimizer]
            [polyquery.plan.physical :as physical]
            [polyquery.plan.rules.column-pruning :as column-pruning]))

(set! *warn-on-reflection* true)

(defn logical-plan
  "The optimized logical plan of a bound query (options as for plan-query)."
  [bq options]
  (-> (optimizer/apply-rule column-pruning/prune-columns (logical/plan-query bq))
      (optimizer/optimize options)))

(defn plan-query
  "Plans a bound query: logical plan → optimization → physical plan.
  options: the query options (polyquery.plan.physical/plan), among them
  :optimize (default true)."
  [bq options]
  (physical/plan (logical-plan bq options) options))
