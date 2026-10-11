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
            [polyquery.plan.physical :as physical]
            [polyquery.plan.planner :as planner]
            [polyquery.result :as result]
            [polyquery.sql.analyzer :as analyzer]
            [polyquery.sql.parser :as parser]
            [polyquery.storage.index :as index]
            [polyquery.storage.table :as table]
            [polyquery.util.json :as json]
            [polyquery.util.log :as log])
  (:import (clojure.lang ExceptionInfo)))

(set! *warn-on-reflection* true)

(defn- limited-rows
  "rows, failing with RESOURCE_LIMIT when there are more than max-rows."
  [rows max-rows]
  (if max-rows
    (let [max-rows (long max-rows)]
      (eduction
       (map-indexed (fn [^long i row]
                      (when (>= i max-rows)
                        (err/fail! "RESOURCE_LIMIT" (str "result exceeds max_rows (" max-rows ")")))
                      row))
       rows))
    rows))

(defn- plan-options
  [opts]
  (select-keys opts [:optimize :join :use-indexes :mode :threads :default-threads :native]))

(defn- analyze
  [catalog ^String sql opts]
  (analyzer/analyze-statement catalog (parser/parse-statement sql)
                              {:test-functions? (:test-functions? opts)}))

(defn plan-statement
  "Parses, analyzes and plans one SQL query. Returns {:kind :query|:explain
  :plan physical-plan}."
  [catalog ^String sql opts]
  (let [{:keys [kind query]} (analyze catalog sql opts)]
    (when-not (#{:query :explain} kind)
      (err/fail! "SEMANTIC_ERROR" "only queries can be planned"))
    {:kind kind :query query :plan (planner/plan-query query (plan-options opts))}))

(defn explain-plan
  "EXPLAIN tree (JSON-ready map) of a SQL query (an EXPLAIN prefix is
  accepted)."
  [catalog sql opts]
  (explain/plan->json (:plan (plan-statement catalog sql opts))))

(defn- execute
  "Rows of a physical plan, executed as its :execution says."
  [plan qctx opts]
  (let [{:keys [mode native?]} (:execution plan)
        env (dispatch/environment qctx {:mode mode :max-join-rows (:max-join-rows opts)
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

(defn- subquery-rows-fn
  "(fn [plan]) → reducible of the rows of a subquery plan evaluated while
  planning, executed vectorized (polyquery.plan.physical/plan-expr)."
  [qctx opts]
  (let [env (dispatch/environment qctx {:mode :vectorized :max-join-rows (:max-join-rows opts)
                                        :native (when (:native opts) (ffi/library))})]
    (fn [plan] (dispatch/build plan env))))

(defn- execution-plan
  "Physical plan of a query for execution. Unless it runs in row mode (the
  unoptimized baseline), its uncorrelated subqueries (and correlated EXISTS
  subqueries that amount to a semi-join) are evaluated once while planning
  and replaced by their results, so that the expressions containing them
  can be vectorized and parallelized. When that evaluation
  fails as described above, the query is planned without it: its outcome is
  then decided by regular execution, which evaluates the subquery only
  where the row engine would."
  [query qctx opts]
  (let [popts (plan-options opts)
        plain #(planner/plan-query query popts)]
    (if (= :row (physical/execution-mode popts))
      (plain)
      (try
        (planner/plan-query query (assoc popts :subquery-rows
                                         (subquery-rows-fn (ctx/derive-context qctx) opts)))
        (catch RuntimeException e
          (if (retry-in-row-mode? e) (plain) (throw e)))))))

(defn- open-plan
  "Opens a planned (EXPLAIN) or analyzed query (its :plan is computed here
  by execution-plan when absent)."
  [{:keys [kind query plan]} opts]
  (let [qctx (ctx/make-context opts)
        plan (or plan (execution-plan query qctx opts))
        serialize #(limited-rows % (:max-rows opts))]
    (if (= kind :explain)
      {:columns [{"name" "plan" "type" "STRING"}]
       :types [:string]
       :rows (serialize [(object-array [(json/write-str (explain/plan->json plan))])])
       :ctx qctx}
      (let [{:keys [mode threads]} (:execution plan)
            rows (serialize (execute plan qctx opts))
            fallback (when (or (= mode :vectorized) (> (long threads) 1))
                       (delay
                         (let [fctx (ctx/derive-context qctx)
                               serial (planner/plan-query query (assoc (plan-options opts)
                                                                       :mode "row" :threads 1))]
                           {:rows (serialize (execute serial fctx opts)) :ctx fctx})))]
        (cond-> {:columns (table/columns-json (:columns plan))
                 :types (mapv :type (:columns plan))
                 :rows (if fallback (with-fallback rows fallback) rows)
                 :ctx qctx}
          fallback (assoc :primary {:rows rows :ctx qctx} :fallback fallback))))))

(defn- collect-rows
  [rows qctx ^long ncols sink]
  (let [n (reduce (fn [^long n row]
                    (when (zero? (rem n 4096))
                      (ctx/check! qctx)
                      (ctx/reserve! qctx (* 4096 (ctx/row-bytes ncols))))
                    (result/accept! sink row)
                    (inc n))
                  0
                  rows)]
    {:rows (result/rows sink) :row-count n}))

(defn collect
  "Materializes an opened statement (see open-statement!) into
  {:columns :rows :row-count n}, accounting the result against the query's
  memory budget. encoding (polyquery.result/sink): :values (default; rows
  as Object[]s of JSON values), :json-text (rows as one json/raw value) or
  :count (no rows)."
  ([opened] (collect opened :values))
  ([{:keys [columns types rows ctx primary fallback]} encoding]
   (let [ncols (count columns)
         new-sink #(result/sink encoding types)
         out (if fallback
               (try
                 (collect-rows (:rows primary) (:ctx primary) ncols (new-sink))
                 (catch RuntimeException e
                   (if (retry-in-row-mode? e)
                     (let [{:keys [rows ctx]} (force fallback)]
                       (collect-rows rows ctx ncols (new-sink)))
                     (throw e))))
               (collect-rows rows ctx ncols (new-sink)))]
     (assoc out :columns columns))))

(defn json-rows
  "Reducible of the rows of an opened statement as Object[]s of JSON values."
  [{:keys [types rows]}]
  (eduction (map (result/json-row-fn types)) rows))

(defn run-query
  "Executes one SQL query against a catalog snapshot. opts:
  :max-rows :timeout-ms :memory-budget-bytes :max-join-rows :test-functions?
  :count-only? :optimize :join :use-indexes :mode (\"auto\" \"row\" \"vectorized\")
  :threads :default-threads :native (use the loaded native kernel library).
  Returns {:columns [{\"name\" \"type\"}] :rows [[…]] :row-count n}."
  [catalog ^String sql opts]
  (let [{:keys [kind query]} (analyze catalog sql opts)]
    (when-not (#{:query :explain} kind)
      (err/fail! "SEMANTIC_ERROR" "only queries can be planned"))
    (collect (open-plan {:kind kind :query query
                         :plan (when (= kind :explain) (planner/plan-query query (plan-options opts)))}
                        opts))))

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
  [{\"name\" \"type\"}] :types [column-type] :rows reducible-of-engine-rows
  :ctx query-context}; the rows are computed while they are reduced (see
  collect and json-rows). Same options as run-query
  (plus :cancel-flag/:deadline-ns, see polyquery.exec.context)."
  [catalog-atom ^String sql opts]
  (let [analyzed (analyze @catalog-atom sql opts)
        empty-result (fn [] {:columns [] :types [] :rows [] :ctx (ctx/make-context opts)})]
    (case (:kind analyzed)
      :create-index (do (catalog/update! catalog-atom (create-index analyzed)) (empty-result))
      :drop-index (do (catalog/update! catalog-atom (drop-index analyzed)) (empty-result))
      (let [{:keys [kind query]} analyzed]
        (open-plan {:kind kind :query query
                    :plan (when (= kind :explain) (planner/plan-query query (plan-options opts)))}
                   opts)))))

(defn execute!
  "Executes one SQL statement against the catalog atom (see open-statement!).
  Same options and result as run-query."
  [catalog-atom ^String sql opts]
  (collect (open-statement! catalog-atom sql opts)))
