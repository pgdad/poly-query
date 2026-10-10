(ns polyquery.engine
  "Query pipeline: lex/parse → analyze → plan → execute → serialize
  (spec/sql/semantics.md: errors detected before execution are reported
  without executing anything)."
  (:require [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.exec.operators :as ops]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.sql.planner :as planner]
            [polyquery.storage.table :as table]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(defn- eval-count-clause
  "Evaluates a bound LIMIT/OFFSET expression to a non-negative long or nil."
  [env e what]
  (when e
    (let [x (expr/eval-constant env e)]
      (when (and (some? x) (neg? (long x)))
        (err/fail! "INVALID_ARGUMENT" (str what " must not be negative")))
      x)))

(defn- collect-rows
  "Reduces the plan into a vector of JSON-ready rows, enforcing max-rows."
  [plan env max-rows]
  (let [types (mapv :type (:columns plan))
        ncols (count types)
        qctx (:ctx env)
        max-rows (long (or max-rows Long/MAX_VALUE))]
    (persistent!
     (reduce (fn [acc ^objects row]
               (when (>= (count acc) max-rows)
                 (err/fail! "RESOURCE_LIMIT" (str "result exceeds max_rows (" max-rows ")")))
               (when (zero? (rem (count acc) 4096))
                 (ctx/reserve! qctx (* 4096 (ctx/row-bytes ncols))))
               (conj! acc (let [out (object-array ncols)]
                            (dotimes [i ncols]
                              (aset out i (v/value->json (nth types i) (aget row i))))
                            out)))
             (transient [])
             (ops/execute plan env)))))

(defn run-query
  "Executes one SQL statement against a catalog snapshot. opts:
  :max-rows :timeout-ms :memory-budget-bytes :test-functions?
  Returns {:columns [{\"name\" \"type\"}] :rows [[…]] :row-count n}."
  [catalog ^String sql opts]
  (let [qctx (ctx/make-context opts)
        env {:ctx qctx}
        stmt (parser/parse-statement sql)
        {:keys [query]} (analyzer/analyze-statement catalog stmt {:test-functions? (:test-functions? opts)})
        limit (eval-count-clause env (:limit query) "LIMIT")
        offset (eval-count-clause env (:offset query) "OFFSET")
        plan (planner/plan-query query limit offset)
        rows (collect-rows plan env (:max-rows opts))]
    {:columns (table/columns-json (:columns plan))
     :rows rows
     :row-count (count rows)}))
