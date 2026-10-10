(ns polyquery.engine
  "Query pipeline: lex/parse → semantic analysis → logical plan →
  optimization → physical plan → execution → serialization
  (spec/sql/semantics.md: errors detected before execution are reported
  without executing anything)."
  (:require [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.join]
            [polyquery.exec.operators :as ops]
            [polyquery.plan.explain :as explain]
            [polyquery.plan.physical :as physical]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.storage.table :as table]
            [polyquery.util.json :as json]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(defn- collect-rows
  "Reduces the rows into a vector of JSON-ready rows, enforcing max-rows.
  With count-only? the rows are counted but not serialized."
  [rows columns qctx max-rows count-only?]
  (let [types (mapv :type columns)
        ncols (count types)
        max-rows (long (or max-rows Long/MAX_VALUE))]
    (persistent!
     (reduce (fn [acc ^objects row]
               (when (>= (count acc) max-rows)
                 (err/fail! "RESOURCE_LIMIT" (str "result exceeds max_rows (" max-rows ")")))
               (when (zero? (rem (count acc) 4096))
                 (ctx/reserve! qctx (* 4096 (ctx/row-bytes ncols))))
               (conj! acc (if count-only?
                            nil
                            (let [out (object-array ncols)]
                              (dotimes [i ncols]
                                (aset out i (v/value->json (nth types i) (aget row i))))
                              out))))
             (transient [])
             rows))))

(defn- plan-options
  [opts]
  {:optimize (:optimize opts) :join (:join opts)})

(defn plan-statement
  "Parses, analyzes and plans one SQL statement. Returns
  {:kind :query|:explain :plan physical-plan}."
  [catalog ^String sql opts]
  (let [stmt (parser/parse-statement sql)
        {:keys [kind query]} (analyzer/analyze-statement catalog stmt
                                                         {:test-functions? (:test-functions? opts)})]
    {:kind kind :plan (physical/plan-query query (plan-options opts))}))

(defn explain-plan
  "EXPLAIN tree (JSON-ready map) of a SQL query (an EXPLAIN prefix is
  accepted)."
  [catalog sql opts]
  (explain/plan->json (:plan (plan-statement catalog sql opts))))

(defn- execute
  [plan qctx opts]
  (let [env {:ctx qctx :cells (atom {}) :build ops/build :max-join-rows (:max-join-rows opts)}]
    (ops/build plan env)))

(defn run-query
  "Executes one SQL statement against a catalog snapshot. opts:
  :max-rows :timeout-ms :memory-budget-bytes :max-join-rows :test-functions?
  :count-only? :optimize :join.
  Returns {:columns [{\"name\" \"type\"}] :rows [[…]] :row-count n}."
  [catalog ^String sql opts]
  (let [qctx (ctx/make-context opts)
        {:keys [kind plan]} (plan-statement catalog sql opts)]
    (if (= kind :explain)
      (let [text (json/write-str (explain/plan->json plan))]
        {:columns [{"name" "plan" "type" "STRING"}]
         :rows (if (:count-only? opts) [nil] [[text]])
         :row-count 1})
      (let [rows (collect-rows (execute plan qctx opts) (:columns plan) qctx
                               (:max-rows opts) (:count-only? opts))]
        {:columns (table/columns-json (:columns plan))
         :rows rows
         :row-count (count rows)}))))
