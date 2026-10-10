(ns polyquery.engine
  "Query pipeline: lex/parse → semantic analysis → logical plan →
  optimization → physical plan → execution → serialization
  (spec/sql/semantics.md: errors detected before execution are reported
  without executing anything)."
  (:require [polyquery.catalog :as catalog]
            [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.join]
            [polyquery.exec.operators :as ops]
            [polyquery.plan.explain :as explain]
            [polyquery.plan.physical :as physical]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.storage.index :as index]
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
  {:optimize (:optimize opts) :join (:join opts) :use-indexes (:use-indexes opts)})

(defn- analyze
  [catalog ^String sql opts]
  (analyzer/analyze-statement catalog (parser/parse-statement sql)
                              {:test-functions? (:test-functions? opts)}))

(defn plan-statement
  "Parses, analyzes and plans one SQL query. Returns {:kind :query|:explain
  :plan physical-plan}."
  [catalog ^String sql opts]
  (let [{:keys [kind query] :as analyzed} (analyze catalog sql opts)]
    (when-not (#{:query :explain} kind)
      (err/fail! "SEMANTIC_ERROR" "only queries can be planned"))
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

(defn- run-plan
  [{:keys [kind plan]} opts]
  (let [qctx (ctx/make-context opts)]
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

(defn run-query
  "Executes one SQL query against a catalog snapshot. opts:
  :max-rows :timeout-ms :memory-budget-bytes :max-join-rows :test-functions?
  :count-only? :optimize :join :use-indexes.
  Returns {:columns [{\"name\" \"type\"}] :rows [[…]] :row-count n}."
  [catalog ^String sql opts]
  (run-plan (plan-statement catalog sql opts) opts))

;; ---------------------------------------------------------------------------
;; Index statements

(defn- create-index
  "Catalog function adding the index described by the analyzed statement."
  [{:keys [index-name table column-index index-kind if-not-exists?]}]
  (fn [catalog]
    (cond
      (catalog/index-table catalog index-name)
      (if if-not-exists?
        catalog
        (err/fail! "ALREADY_EXISTS" (str "index '" index-name "' already exists")))

      :else
      (let [tbl (catalog/lookup! catalog table)]
        (catalog/create-index catalog table (index/build tbl index-name column-index index-kind))))))

(defn- drop-index
  [{:keys [index-name if-exists?]}]
  (fn [catalog]
    (if (and if-exists? (nil? (catalog/index-table catalog index-name)))
      catalog
      (catalog/drop-index catalog index-name))))

(def ^:private statement-result {:columns [] :rows [] :row-count 0})

(defn execute!
  "Executes one SQL statement against the catalog atom: index statements
  update the catalog atomically, queries run on a snapshot. Same options and
  result as run-query."
  [catalog-atom ^String sql opts]
  (let [analyzed (analyze @catalog-atom sql opts)]
    (case (:kind analyzed)
      :create-index (do (catalog/update! catalog-atom (create-index analyzed)) statement-result)
      :drop-index (do (catalog/update! catalog-atom (drop-index analyzed)) statement-result)
      (run-plan {:kind (:kind analyzed)
                 :plan (physical/plan-query (:query analyzed) (plan-options opts))}
                opts))))
