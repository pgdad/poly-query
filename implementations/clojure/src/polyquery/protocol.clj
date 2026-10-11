(ns polyquery.protocol
  "Protocol request handling (spec/protocol/protocol.md §4-§6): request
  validation, dispatch of operations and construction of response objects.
  Transport-independent: used by the session and exec CLI modes and by the
  HTTP server."
  (:require [clojure.string :as str]
            [polyquery.catalog :as catalog]
            [polyquery.engine :as engine]
            [polyquery.errors :as err]
            [polyquery.ingest :as ingest]
            [polyquery.native.ffi :as ffi]
            [polyquery.storage.index :as index]
            [polyquery.storage.pqcf :as pqcf]
            [polyquery.storage.stats :as stats]
            [polyquery.storage.table :as table]
            [polyquery.types :as t]
            [polyquery.util.log :as log]
            [polyquery.values :as v])
  (:import (java.io File)))

(set! *warn-on-reflection* true)

(def engine-version "0.1.0")
(def protocol-version 1)
(def spec-version "1.0.0")

(def capabilities
  ["phase1" "ingest.csv" "ingest.json" "ingest.jsonl" "sql.basic" "test.functions"
   "phase2" "sql.groupby" "sql.join" "sql.functions" "sql.subquery" "sql.cte"
   "sql.correlated_subquery"
   "phase3" "storage.pqcf" "storage.mmap" "index.hash" "index.btree"
   "phase4" "http.streaming"
   "phase5" "exec.row" "exec.vectorized" "exec.parallel" "join.hash" "join.merge" "join.nested_loop"
   "native.kernels"
   "change.union_all" "change.decimal38"])

(defn version-info []
  {"ok" true
   "engine" "polyquery-clojure"
   "engine_version" engine-version
   "language" "clojure"
   "protocol_version" protocol-version
   "spec_version" spec-version
   "runtime" (str "Clojure " (clojure-version) " on Java " (System/getProperty "java.version"))
   "build" (cond-> {"profile" "release" "flags" "aot,direct-linking"}
             (ffi/info) (assoc "native_kernels" (ffi/info)))})

(defn capabilities-info []
  {"ok" true "protocol_version" protocol-version "capabilities" capabilities})

;; ---------------------------------------------------------------------------
;; Engine state

(defn make-state
  "config: {:data-dir File :test-functions? bool :limits {...}}"
  [config]
  {:config config
   :catalog (atom catalog/empty-catalog)})

;; ---------------------------------------------------------------------------
;; Request field validation

(defn- invalid! [msg] (err/fail! "INVALID_REQUEST" msg))

(defn- field
  "Returns field k of the request validated by pred (nil when absent and not
  required)."
  [req k pred expected required?]
  (let [present? (contains? req k)
        x (get req k)]
    (cond
      (and (not present?) required?) (invalid! (str "missing field '" k "'"))
      (not present?) nil
      (and (nil? x) (not required?)) nil
      (pred x) x
      :else (invalid! (str "field '" k "' must be " expected)))))

(defn- non-empty-string? [x] (and (string? x) (not (str/blank? x))))
(defn- int-value? [x] (instance? Long x))
(defn- non-neg-int? [x] (and (int-value? x) (>= (long x) 0)))

;; ---------------------------------------------------------------------------
;; Path safety (protocol.md §6)

(defn resolve-path
  "Resolves a request path inside the data directory. Lexical checks only:
  symbolic links inside the data directory are followed."
  ^File [^File data-dir ^String path]
  (when (or (empty? path)
            (str/includes? path "\u0000")
            (str/starts-with? path "/")
            (str/starts-with? path "\\")
            (re-find #"^[A-Za-z]:" path)
            (some #(= ".." %) (str/split path #"[/\\]")))
    (err/fail! "ACCESS_DENIED" (str "path '" path "' is not allowed")))
  (File. data-dir path))

;; ---------------------------------------------------------------------------
;; Operations

(defmulti handle-op
  "Handles a validated request map (string keys); returns the op-specific
  part of the success response."
  (fn [_state req] (get req "op")))

(defn- parse-schema [schema]
  (when-not (and (vector? schema)
                 (every? #(and (map? %) (string? (get % "name")) (string? (get % "type"))) schema))
    (invalid! "field 'schema' must be an array of {\"name\", \"type\"} objects"))
  (mapv (fn [c] (table/->Column (get c "name") (t/parse-type-string (get c "type") "INVALID_REQUEST")))
        schema))

(defn- storage-options
  "Table layout options of a load/open request (indexes-and-planning.md §1)."
  [options]
  (let [layout (get options "layout" "column")
        dictionary (get options "dictionary" :auto)]
    (when-not (#{"row" "column"} layout)
      (invalid! "option 'layout' must be \"row\" or \"column\""))
    (when-not (or (boolean? dictionary) (= :auto dictionary))
      (invalid! "option 'dictionary' must be a boolean"))
    {:layout (keyword layout) :dictionary dictionary}))

(defmethod handle-op "load"
  ;; Besides "path"/"data", the HTTP server passes a raw request body as
  ;; ::data-bytes (a byte array; not expressible in JSON requests).
  [{:keys [config catalog]} req]
  (let [tname (field req "table" non-empty-string? "a non-empty string" true)
        fmt (field req "format" string? "a string" true)
        _ (when-not (#{"csv" "json" "jsonl"} fmt)
            (invalid! (str "unknown format '" fmt "'")))
        path (field req "path" string? "a string" false)
        data (field req "data" string? "a string" false)
        data-bytes (get req ::data-bytes)
        _ (when-not (= 1 (count (filter some? [path data data-bytes])))
            (invalid! "exactly one of 'path' or 'data' is required"))
        schema (some-> (field req "schema" vector? "an array" false) parse-schema)
        options (or (field req "options" map? "an object" false) {})
        header? (let [h (get options "header" true)]
                  (if (boolean? h) h (invalid! "option 'header' must be a boolean")))
        delimiter (let [d (get options "delimiter" ",")]
                    (if (and (string? d) (= 1 (count d)) (< (int (first d)) 128)
                             (not (#{\" \newline \return} (first d))))
                      (first d)
                      (invalid! "option 'delimiter' must be a single ASCII character")))
        replace? (boolean (field req "replace" boolean? "a boolean" false))
        storage (storage-options options)
        _ (when (and (= fmt "csv") (not header?) (nil? schema))
            (invalid! "CSV without header requires an explicit schema"))
        source (cond
                 path {:file (resolve-path (:data-dir config) path)}
                 data-bytes {:bytes data-bytes}
                 :else {:text data})
        _ (when (and (not replace?) (catalog/lookup @catalog tname))
            (err/fail! "ALREADY_EXISTS" (str "table '" tname "' already exists") {"table" tname}))
        tbl (stats/with-stats
              (ingest/load-table {:name tname :format fmt :source source :schema schema
                                  :header? header? :delimiter delimiter :limits (:limits config)
                                  :storage storage}))]
    (swap! catalog catalog/add-table tbl replace?)
    {"table" (:name tbl)
     "row_count" (:row-count tbl)
     "columns" (table/columns-json (:columns tbl))}))

(def ^:private enum-options
  {"result" #{"rows" "count"}
   "mode" #{"auto" "row" "vectorized"}
   "join" #{"auto" "hash" "merge" "nested_loop"}})

(defn- query-options [opts]
  (doseq [[k allowed] enum-options]
    (when (contains? opts k)
      (let [x (get opts k)]
        (when-not (string? x) (invalid! (str "option '" k "' must be a string")))
        (when-not (allowed x)
          (err/fail! "UNSUPPORTED" (str "option " k "=" x " is not supported"))))))
  (doseq [k ["optimize" "use_indexes" "native"]]
    (when (and (contains? opts k) (not (boolean? (get opts k))))
      (invalid! (str "option '" k "' must be a boolean"))))
  (when (contains? opts "threads")
    (let [n (get opts "threads")]
      (cond
        (not (int-value? n)) (invalid! "option 'threads' must be an integer >= 1")
        (not (pos? (long n))) (err/fail! "UNSUPPORTED" (str "option threads=" n " is not supported")))))
  (when (and (contains? opts "query_id") (not (string? (get opts "query_id"))))
    (invalid! "option 'query_id' must be a string"))
  {:max-rows (field opts "max_rows" non-neg-int? "an integer >= 0" false)
   :timeout-ms (field opts "timeout_ms" non-neg-int? "an integer >= 0" false)
   :count-only? (= "count" (get opts "result"))
   :optimize (get opts "optimize" true)
   :use-indexes (get opts "use_indexes" true)
   :join (get opts "join" "auto")
   :mode (get opts "mode" "auto")
   :threads (get opts "threads")
   :native (get opts "native" false)})

(defn- engine-options
  "Engine options of a query/explain request. A server controlling the query
  from outside puts :cancel-flag/:deadline-ns (polyquery.exec.context) into
  the state's :query-control."
  [{:keys [config query-control]} req]
  (merge (query-options (or (field req "options" map? "an object" false) {}))
         {:test-functions? (:test-functions? config)
          :default-threads (:threads config)
          :max-join-rows (:max-join-rows (:limits config))
          :memory-budget-bytes (* 1024 1024 (long (:max-query-memory-mb (:limits config))))}
         query-control))

(defn open-query
  "Validates a query request and opens its statement (engine/open-statement!):
  returns {:columns :rows reducible :ctx :count-only?}. Throws for invalid
  requests and for errors detectable before execution."
  [{:keys [catalog] :as state} req]
  (let [sql (field req "sql" string? "a string" true)
        opts (engine-options state req)]
    (assoc (engine/open-statement! catalog sql opts) :count-only? (:count-only? opts))))

(defmethod handle-op "query" [state req]
  (let [started (System/nanoTime)
        opened (open-query state req)
        result (engine/collect opened (if (:count-only? opened) :count :json-text))
        elapsed-us (quot (- (System/nanoTime) started) 1000)]
    (cond-> {"columns" (:columns result)}
      (not (:count-only? opened)) (assoc "rows" (:rows result))
      true (assoc "row_count" (:row-count result)
                  "stats" {"elapsed_us" elapsed-us}))))

(defmethod handle-op "tables" [{:keys [catalog]} _req]
  {"tables" (mapv (fn [tbl] {"name" (:name tbl) "row_count" (:row-count tbl)})
                  (catalog/tables @catalog))})

(defn- indexes-json [tbl]
  (mapv (fn [idx] {"name" (:name idx) "column" (:column idx) "kind" (index/kind-name (:kind idx))})
        (:indexes tbl)))

(defmethod handle-op "schema" [{:keys [catalog]} req]
  (let [tbl (catalog/lookup! @catalog (field req "table" string? "a string" true))]
    {"table" (:name tbl)
     "row_count" (:row-count tbl)
     "columns" (table/columns-json (:columns tbl))
     "indexes" (indexes-json tbl)
     "layout" (name (:layout tbl))
     "dictionary_columns" (table/dictionary-columns tbl)}))

(defmethod handle-op "stats" [{:keys [catalog]} req]
  (let [tbl (catalog/lookup! @catalog (field req "table" string? "a string" true))]
    {"table" (:name tbl)
     "row_count" (:row-count tbl)
     "columns" (vec (map-indexed
                     (fn [i c]
                       (let [{:keys [null-count distinct-count min max]} (stats/column-stats tbl i)
                             t (:type c)]
                         {"name" (:name c) "type" (t/type-name t)
                          "null_count" null-count "distinct_count" distinct-count
                          "min" (v/value->json t min) "max" (v/value->json t max)}))
                     (:columns tbl)))}))

;; ---------------------------------------------------------------------------
;; PQCF storage (protocol.md §5.7)

(defmethod handle-op "save" [{:keys [config catalog]} req]
  (let [tname (field req "table" string? "a string" true)
        path (field req "path" string? "a string" true)
        options (or (field req "options" map? "an object" false) {})
        rg (field options "row_group_size" #(and (int-value? %) (pos? (long %))) "an integer >= 1" false)
        encoding (or (field options "encoding" string? "a string" false) "auto")
        _ (when-not (#{"auto" "plain" "dict" "rle"} encoding)
            (err/fail! "UNSUPPORTED" (str "encoding '" encoding "' is not supported")))
        file (resolve-path (:data-dir config) path)
        tbl (catalog/lookup! @catalog tname)
        size (pqcf/save! tbl file {:row-group-size rg :encoding encoding})]
    {"path" path "bytes" size}))

(defn- open-table
  "Builds the catalog table of an opened PQCF file, recreating its indexes."
  [tname {:keys [columns row-count segments indexes]} storage]
  (let [tbl (table/->Table tname columns row-count :column segments [] nil)
        tbl (if (= :row (:layout storage))
              (table/make-table tname columns (mapv #(table/column-array tbl %) (range (count columns)))
                                row-count storage)
              tbl)
        tbl (stats/with-stats tbl)]
    (assoc tbl :indexes (mapv (fn [{:keys [name column-index kind]}] (index/build tbl name column-index kind))
                              indexes))))

(defmethod handle-op "open" [{:keys [config catalog]} req]
  (let [tname (field req "table" non-empty-string? "a non-empty string" true)
        path (field req "path" string? "a string" true)
        options (or (field req "options" map? "an object" false) {})
        mmap? (boolean (field options "mmap" boolean? "a boolean" false))
        storage (storage-options options)
        replace? (boolean (field req "replace" boolean? "a boolean" false))
        file (resolve-path (:data-dir config) path)
        _ (when (and (not replace?) (catalog/lookup @catalog tname))
            (err/fail! "ALREADY_EXISTS" (str "table '" tname "' already exists") {"table" tname}))
        contents (pqcf/open file {:mmap? (and mmap? (= :column (:layout storage)))
                                  :max-rows (:max-table-rows (:limits config))})
        _ (catalog/check-index-names! @catalog (map :name (:indexes contents)) (when replace? tname))
        tbl (open-table tname contents storage)]
    (swap! catalog catalog/add-table tbl replace?)
    {"table" (:name tbl)
     "row_count" (:row-count tbl)
     "columns" (table/columns-json (:columns tbl))}))

(defmethod handle-op "drop" [{:keys [catalog]} req]
  (let [tname (field req "table" string? "a string" true)]
    (swap! catalog catalog/drop-table tname)
    {}))

(defmethod handle-op "reset" [{:keys [catalog]} _req]
  (reset! catalog catalog/empty-catalog)
  {})

(defmethod handle-op "version" [_ _] (dissoc (version-info) "ok"))

(defmethod handle-op "capabilities" [_ _] (dissoc (capabilities-info) "ok"))

(defmethod handle-op "sleep" [{:keys [config]} req]
  (when-not (:test-functions? config)
    (invalid! "the sleep operation requires --enable-test-functions"))
  (let [ms (field req "ms" non-neg-int? "an integer >= 0" true)]
    (Thread/sleep (long ms))
    {}))

(defmethod handle-op "explain" [{:keys [catalog] :as state} req]
  (let [sql (field req "sql" string? "a string" true)]
    {"plan" (engine/explain-plan @catalog sql (engine-options state req))}))

(defmethod handle-op :default [_ req]
  (invalid! (str "unknown op '" (get req "op") "'")))

;; ---------------------------------------------------------------------------

(defn error-response [id ^Throwable t]
  {"id" id "ok" false "error" (err/->error-object t)})

(defn handle-request
  "Handles a parsed request value (any JSON value). Never throws."
  [state req]
  (if-not (map? req)
    (error-response nil (err/error "INVALID_REQUEST" "request must be a JSON object"))
    (let [id (get req "id")]
      (try
        (when-not (string? (get req "op"))
          (invalid! "missing or invalid field 'op'"))
        (merge {"id" id "ok" true} (handle-op state req))
        (catch Throwable t
          (when-not (err/error-code t)
            (log/error "request failed" {"op" (get req "op") "exception" (str t)})
            (when (log/enabled? :debug) (.printStackTrace t)))
          (error-response id t))))))
