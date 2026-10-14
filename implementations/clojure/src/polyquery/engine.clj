(ns polyquery.engine
  "Query pipeline: lex/parse → semantic analysis → planning (logical plan →
  optimization → physical plan, polyquery.plan.planner) → execution →
  serialization
  (spec/sql/semantics.md: errors detected before execution are reported
  without executing anything)."
  (:require [polyquery.catalog :as catalog]
            [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.dispatch :as dispatch]
            [polyquery.native.ffi :as ffi]
            [polyquery.plan.explain :as explain]
            [polyquery.plan.planner :as planner]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.storage.index :as index]
            [polyquery.storage.table :as table]
            [polyquery.util.json :as json]
            [polyquery.util.log :as log]
            [polyquery.values :as v])
  (:import (clojure.lang ExceptionInfo)))

(set! *warn-on-reflection* true)

(defn- serialized-rows
  "Reducible of the result rows serialized per types.md §9 (one Object[]
  per row, or nil per row with count-only?), enforcing max-rows. value-fn
  (type, runtime value) → output value does the serialization; nil means
  polyquery.values/value->json (the protocol's JSON values)."
  [rows columns max-rows count-only? value-fn]
  (let [value-fn (or value-fn v/value->json)
        types (mapv :type columns)
        ncols (count types)
        max-rows (long (or max-rows Long/MAX_VALUE))]
    (eduction
     (map-indexed (fn [^long i ^objects row]
                    (when (>= i max-rows)
                      (err/fail! "RESOURCE_LIMIT" (str "result exceeds max_rows (" max-rows ")")))
                    (when-not count-only?
                      (let [out (object-array ncols)]
                        (dotimes [i ncols]
                          (aset out i (value-fn (nth types i) (aget row i))))
                        out))))
     rows)))

(defn- plan-options
  [opts]
  (select-keys opts [:optimize :join :use-indexes :mode :threads :default-threads :native]))

(defn- analyze
  [catalog ^String sql opts]
  (analyzer/analyze-statement catalog (parser/parse-statement sql)
                              {:test-functions? (:test-functions? opts)}))

(defmacro ^:private preparing
  "Evaluates body (parsing, analysis, planning) as the preparation of the
  query with context qctx: the stages poll its deadline and cancellation
  (polyquery.exec.context/poll!), as the timeout covers every stage of a
  query (CR-6 §4)."
  [qctx & body]
  `(binding [ctx/*preparing* ~qctx] ~@body))

(defn- plan-in-context
  [catalog ^String sql opts qctx]
  (preparing qctx
    (let [{:keys [kind query]} (analyze catalog sql opts)]
      (when-not (#{:query :explain} kind)
        (err/fail! "SEMANTIC_ERROR" "only queries can be planned"))
      {:kind kind :query query :plan (planner/plan-query query (plan-options opts))})))

(defn plan-statement
  "Parses, analyzes and plans one SQL query. Returns {:kind :query|:explain
  :plan physical-plan}."
  [catalog ^String sql opts]
  (plan-in-context catalog sql opts (ctx/make-context opts)))

(defn explain-plan
  "EXPLAIN tree (JSON-ready map) of a SQL query (an EXPLAIN prefix is
  accepted)."
  [catalog sql opts]
  (explain/plan->json (:plan (plan-statement catalog sql opts))))

(defn- execute
  "Rows of a physical plan, executed as its :execution says."
  [plan qctx opts]
  (let [{:keys [mode native?]} (:execution plan)
        env (dispatch/environment qctx {:mode mode :max-join-rows (:max-join-rows opts) :plan plan
                                        :native (when native? (ffi/library))})]
    (dispatch/build plan env)))

;; ---------------------------------------------------------------------------
;; Row-mode re-execution
;;
;; Vectorized and parallel execution evaluate expressions for whole batches
;; and partitions, so they may evaluate rows the row engine never reaches
;; (beyond a LIMIT, after the row that fails first). When such an execution
;; fails with a runtime error, the query is re-executed row at a time on a
;; single thread, whose outcome — rows or error — is the answer. Execution
;; is deterministic and side-effect free, so this only costs time on the
;; error path. Unexpected exceptions are handled the same way (and logged).

(def ^:private retried-codes
  #{"NUMERIC_OVERFLOW" "DIVISION_BY_ZERO" "CONVERSION_ERROR" "INVALID_ARGUMENT"
    "SUBQUERY_CARDINALITY" "RESOURCE_LIMIT" "TYPE_ERROR"})

(def ^:private strict?
  "PQ_STRICT_EXECUTION=1 disables the re-execution after unexpected
  exceptions (testing: surfaces defects of the vectorized/parallel engine)."
  (= "1" (System/getenv "PQ_STRICT_EXECUTION")))

(defn- retry-in-row-mode?
  [^Throwable t]
  (if (instance? ExceptionInfo t)
    (contains? retried-codes (err/error-code t))
    (let [retry? (and (instance? RuntimeException t) (nil? (err/error-code t))
                      (not strict?))]
      (when retry?
        (log/warn "vectorized/parallel execution failed; re-executing row at a time"
                  {"exception" (.getName (class t)) "message" (str (.getMessage t))}))
      retry?)))

(defn- with-fallback
  "rows, re-executed by (force fallback) when it fails as described above
  before producing its first row."
  [rows fallback]
  (reify clojure.lang.IReduceInit
    (reduce [_ f init]
      (let [emitted (volatile! false)]
        (try
          (reduce (fn [acc row] (vreset! emitted true) (f acc row)) init rows)
          (catch RuntimeException e
            (if (and (not @emitted) (retry-in-row-mode? e))
              (reduce f init (:rows (force fallback)))
              (throw e))))))))

(defn- open-plan
  [{:keys [kind plan query]} opts qctx]
  (let [serialize #(serialized-rows % (:columns plan) (:max-rows opts) (:count-only? opts)
                                    (:value-fn opts))]
    (if (= kind :explain)
      {:columns [{"name" "plan" "type" "STRING"}]
       :types [:string]
       :rows (serialized-rows [(object-array [(json/write-str (explain/plan->json plan))])]
                              [{:type :string}] (:max-rows opts) (:count-only? opts) (:value-fn opts))
       :ctx qctx}
      (let [{:keys [mode threads]} (:execution plan)
            rows (serialize (execute plan qctx opts))
            fallback (when (or (= mode :vectorized) (> (long threads) 1))
                       (delay
                         (let [fctx (ctx/derive-context qctx)
                               serial (preparing fctx
                                        (planner/plan-query query (assoc (plan-options opts)
                                                                         :mode "row" :threads 1)))]
                           {:rows (serialize (execute serial fctx opts)) :ctx fctx})))]
        (cond-> {:columns (table/columns-json (:columns plan))
                 :types (mapv :type (:columns plan))
                 :rows (if fallback (with-fallback rows fallback) rows)
                 :ctx qctx}
          fallback (assoc :primary {:rows rows :ctx qctx} :fallback fallback))))))

(defn- collect-rows
  [rows qctx ^long ncols]
  (persistent!
   (reduce (fn [acc row]
             (when (zero? (rem (count acc) 4096))
               (ctx/check! qctx)
               (ctx/reserve! qctx (* 4096 (ctx/row-bytes ncols))))
             (conj! acc row))
           (transient [])
           rows)))

(defn- count-rows
  "The number of rows (count-only results: nothing is kept), with the same
  checks and accounting as collect-rows."
  [rows qctx ^long ncols]
  (reduce (fn [^long n _]
            (when (zero? (rem n 4096))
              (ctx/check! qctx)
              (ctx/reserve! qctx (* 4096 (ctx/row-bytes ncols))))
            (inc n))
          0
          rows))

(defn collect
  "Materializes an opened statement (see open-statement!) into
  {:columns :rows [serialized rows] :row-count n}, accounting the result
  against the query's memory budget. With :count-only? only the rows are
  counted (:rows is empty)."
  [{:keys [columns rows ctx primary fallback count-only?]}]
  (let [ncols (count columns)
        run (if count-only?
              (fn [rows ctx] (count-rows rows ctx ncols))
              (fn [rows ctx] (collect-rows rows ctx ncols)))
        out (if fallback
              (try
                (run (:rows primary) (:ctx primary))
                (catch RuntimeException e
                  (if (retry-in-row-mode? e)
                    (let [{:keys [rows ctx]} (force fallback)]
                      (run rows ctx))
                    (throw e))))
              (run rows ctx))]
    (if count-only?
      {:columns columns :rows [] :row-count out}
      {:columns columns :rows out :row-count (count out)})))

(defn run-query
  "Executes one SQL query against a catalog snapshot. opts:
  :max-rows :timeout-ms :memory-budget-bytes :max-join-rows :test-functions?
  :count-only? :optimize :join :use-indexes :mode (\"auto\" \"row\" \"vectorized\")
  :threads :default-threads :native (use the loaded native kernel library)
  :value-fn (serialization of result values, see serialized-rows).
  Returns {:columns [{\"name\" \"type\"}] :rows [[…]] :row-count n}."
  [catalog ^String sql opts]
  (let [qctx (ctx/make-context opts)
        planned (plan-in-context catalog sql opts qctx)]
    (collect (assoc (preparing qctx (open-plan planned opts qctx)) :count-only? (:count-only? opts)))))

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

(defn open-statement!
  "Prepares one SQL statement against the catalog atom: index statements
  update the catalog atomically (and yield an empty result), queries and
  EXPLAIN are analyzed and planned on a snapshot of the catalog. Errors
  detectable before execution are thrown here. Returns {:columns
  [{\"name\" \"type\"}] :rows reducible-of-serialized-rows :ctx query-context};
  the rows are computed while they are reduced. Same options as run-query
  (plus :cancel-flag/:deadline-ns, see polyquery.exec.context)."
  [catalog-atom ^String sql opts]
  (let [qctx (ctx/make-context opts)]
    (preparing qctx
      (let [analyzed (analyze @catalog-atom sql opts)
            empty-result (fn [] {:columns [] :types [] :rows [] :ctx qctx})]
        (case (:kind analyzed)
          :create-index (do (catalog/update! catalog-atom (create-index analyzed)) (empty-result))
          :drop-index (do (catalog/update! catalog-atom (drop-index analyzed)) (empty-result))
          (open-plan {:kind (:kind analyzed)
                      :query (:query analyzed)
                      :plan (planner/plan-query (:query analyzed) (plan-options opts))}
                     opts qctx))))))

(defn execute!
  "Executes one SQL statement against the catalog atom (see open-statement!).
  Same options and result as run-query."
  [catalog-atom ^String sql opts]
  (collect (open-statement! catalog-atom sql opts)))
