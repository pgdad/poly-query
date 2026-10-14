(ns polyquery.api
  "The embedding API (spec/apps/embedding.md): the PolyQuery engine as an
  in-process library. See EMBEDDING.md for the guide.

    (require '[polyquery.api :as pq])
    (with-open [db (pq/create {:data-dir \"data\"})]
      (pq/load! db \"t\" {:path \"t.csv\"})
      (pq/rows (pq/query db \"SELECT COUNT(*) FROM t\")))   ;=> [[3]]

  An instance (`create`) owns a catalog of in-memory tables and a data
  directory that every file path is resolved against (path safety as for
  --data-dir, spec/protocol/protocol.md §6). Every operation runs in the
  calling thread; nothing starts a process or opens a socket.

  Operations share the protocol's implementation (polyquery.protocol), so
  they validate and behave exactly as the protocol operations of the same
  names. Errors are thrown as ex-info whose data carries :polyquery/code
  (the specification's error code, e.g. \"PARSE_ERROR\") and, when present,
  :polyquery/details; the instance stays usable after an error.

  Instances are safe for concurrent use from several threads: queries run on
  a consistent snapshot of the catalog, and catalog changes (load, open,
  drop, CREATE INDEX) are published atomically."
  (:require [clojure.string :as str]
            [polyquery.api.values :as values]
            [polyquery.catalog :as catalog]
            [polyquery.engine :as engine]
            [polyquery.errors :as err]
            [polyquery.ingest.common :as ingest]
            [polyquery.protocol :as protocol]
            [polyquery.storage.stats :as stats]
            [polyquery.storage.table :as table]
            [polyquery.types :as t])
  (:import (java.io Closeable File)
           (java.util.concurrent.atomic AtomicBoolean)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Errors

(defn error-code
  "The error code (a string such as \"NOT_FOUND\") of an exception thrown by
  this API, or nil for any other throwable."
  [e]
  (:polyquery/code (ex-data e)))

(defn error-details
  "The details map of an API error (string keys), or nil."
  [e]
  (:polyquery/details (ex-data e)))

(defn- api-error
  "Any throwable as an API error (ex-info with :polyquery/code)."
  ^Throwable [^Throwable e]
  (if (error-code e)
    e
    (let [{:strs [code message details]} (err/->error-object e)]
      (ex-info message (cond-> {:polyquery/code code}
                         details (assoc :polyquery/details details))
               e))))

;; ---------------------------------------------------------------------------
;; Instances

(deftype Engine [state ^AtomicBoolean closed]
  Closeable
  (close [_]
    (when (.compareAndSet closed false true)
      ;; Release the tables (and with them memory-mapped files) for the GC.
      (reset! (:catalog state) catalog/empty-catalog)))
  Object
  (toString [_]
    (str "#<polyquery.api.Engine " (.getPath ^File (:data-dir (:config state)))
         (when (.get closed) " (closed)") ">")))

(defmacro ^:private with-engine
  "Evaluates body with `state` bound to db's engine state, translating every
  failure into an API error."
  [[state db] & body]
  `(let [^Engine db# ~db]
     (try
       (when-not (instance? Engine db#)
         (err/fail! "INVALID_REQUEST" "not a polyquery.api engine instance"))
       (when (.get ^AtomicBoolean (.-closed db#))
         (err/fail! "INVALID_REQUEST" "the engine instance is closed"))
       (let [~state (.-state db#)]
         ~@body)
       (catch Throwable e# (throw (api-error e#))))))

(def ^:private config-limits
  "Configuration keys of `create` that are engine limits (as the CLI options
  --max-query-memory-mb, --max-ingest-bytes, --max-table-rows,
  --max-join-rows)."
  [:max-query-memory-mb :max-ingest-bytes :max-table-rows :max-join-rows])

(defn- check-config! [config]
  (when-not (map? config)
    (err/fail! "INVALID_REQUEST" "the configuration must be a map"))
  (doseq [k (conj config-limits :threads)
          :let [x (get config k)]
          :when (some? x)]
    (when-not (and (int? x) (pos? (long x)))
      (err/fail! "INVALID_REQUEST" (str "configuration " k " must be a positive integer"))))
  (let [dir (:data-dir config)]
    (when-not (or (nil? dir) (string? dir) (instance? File dir))
      (err/fail! "INVALID_REQUEST" "configuration :data-dir must be a string or a java.io.File"))))

(defn create
  "Creates an engine instance. config (all keys optional):
    :data-dir             directory that file paths are resolved against
                          (string or java.io.File; default \".\")
    :max-query-memory-mb  per-query memory limit (default 4096)
    :threads              default worker threads per query (default:
                          min(8, available processors))
    :max-ingest-bytes     largest accepted load input (default 4 GiB)
    :max-table-rows       largest table (default 200,000,000 rows)
    :max-join-rows        largest join result (default 100,000,000 rows)
    :test-functions?      enable PQ_SLEEP and the like (default false)
  The instance implements java.io.Closeable (use with-open, or `close`)."
  (^Engine [] (create {}))
  (^Engine [config]
   (try
     (check-config! config)
     (catch Throwable e (throw (api-error e))))
   (let [dir (:data-dir config ".")]
     (Engine. (protocol/make-state
               {:data-dir (if (instance? File dir) dir (File. ^String dir))
                :test-functions? (boolean (:test-functions? config))
                :threads (:threads config)
                :limits (merge protocol/default-limits (select-keys config config-limits))})
              (AtomicBoolean. false)))))

(defn close
  "Closes the instance and releases its tables; idempotent. Later operations
  on it fail with INVALID_REQUEST."
  [^Engine db]
  (.close db))

(defn closed?
  [^Engine db]
  (.get ^AtomicBoolean (.-closed db)))

;; ---------------------------------------------------------------------------
;; Protocol requests

(defn- request
  "Runs one protocol operation (string-keyed request map) on the state."
  [state op fields]
  (protocol/handle-op state (assoc fields "op" op)))

(defn- columns-out [columns]
  (mapv (fn [{:strs [name type]}] {:name name :type type}) columns))

(defn- table-info [resp]
  {:table (get resp "table")
   :row-count (get resp "row_count")
   :columns (columns-out (get resp "columns"))})

(defn- schema-json
  "Explicit schema: a sequence of {:name :type} maps or [name type] pairs,
  types as canonical type names (\"INT64\", \"DECIMAL(18,2)\", …)."
  [schema]
  (mapv (fn [c]
          (let [[n ty] (if (map? c) [(:name c) (:type c)] c)]
            {"name" n "type" (if (keyword? ty) (name ty) ty)}))
        schema))

(defn- option-json
  "A keyword option value as the protocol's JSON value."
  [x]
  (cond
    (keyword? x) (name x)
    (char? x) (str x)
    :else x))

(defn- options-json
  "{:max-rows 10 :timeout-ms 5} → {\"max_rows\" 10 \"timeout_ms\" 5}."
  [opts]
  (into {} (map (fn [[k x]] [(str/replace (name k) "-" "_") (option-json x)])) opts))

;; ---------------------------------------------------------------------------
;; Operations

(defn load!
  "Loads a table from CSV (or JSON / JSON Lines) text, as the protocol's
  `load` operation. source-opts (exactly one of :path and :text):
    :path       file path, relative to the data directory
    :text       the input itself (a string)
    :format     \"csv\" (default), \"json\" or \"jsonl\"
    :schema     explicit schema: [{:name \"id\" :type \"INT64\"} …] or
                [[\"id\" \"INT64\"] …]; default: inferred
    :header     CSV header row (default true)
    :delimiter  CSV field delimiter, a character or 1-character string
                (default \\,)
    :replace    replace an existing table of that name (default false)
    :layout     :column (default) or :row; :dictionary true/false
  Returns {:table name :row-count n :columns [{:name :type} …]}."
  [db table source-opts]
  (with-engine [state db]
    (let [{:keys [path text format schema replace]} source-opts
          options (options-json (select-keys source-opts [:header :delimiter :layout :dictionary]))]
      (table-info
       (request state "load"
                (cond-> {"table" table "format" (or format "csv")}
                  (some? path) (assoc "path" path)
                  (some? text) (assoc "data" text)
                  (some? schema) (assoc "schema" (schema-json schema))
                  (seq options) (assoc "options" options)
                  (some? replace) (assoc "replace" replace)))))))

(defn load-rows!
  "Creates a table from in-memory native values (see polyquery.api.values
  for the mapping): columns is [{:name :type} …] or [[name type] …] with
  canonical type names, rows a sequence of rows (each a sequence of values in
  column order, nil for NULL). opts: :replace (default false). Returns the
  same as load!."
  ([db table columns rows] (load-rows! db table columns rows {}))
  ([db table columns rows {:keys [replace]}]
   (with-engine [state db]
     (when-not (and (string? table) (not (str/blank? table)))
       (err/fail! "INVALID_REQUEST" "the table name must be a non-empty string"))
     (let [cols (mapv (fn [{:strs [name type]}]
                        (when-not (string? name)
                          (err/fail! "INVALID_REQUEST" "column names must be strings"))
                        (table/->Column name (t/parse-type-string type "INVALID_REQUEST")))
                      (schema-json columns))
           _ (ingest/validate-column-names! (map :name cols))
           ncols (count cols)
           buffers (mapv (fn [_] (java.util.ArrayList.)) cols)
           limits (:limits (:config state))
           n (reduce (fn [^long n row]
                       (let [row (vec row)]
                         (when-not (= ncols (count row))
                           (err/fail! "INVALID_REQUEST"
                                      (str "row " (inc n) " has " (count row) " values, expected " ncols)))
                         (dotimes [i ncols]
                           (.add ^java.util.ArrayList (nth buffers i)
                                 (values/->runtime (:type (nth cols i)) (nth row i))))
                         (when (zero? (rem n 65536)) (ingest/check-row-limit! (inc n) limits))
                         (inc n)))
                     0
                     rows)
           _ (ingest/check-row-limit! n limits)
           tbl (stats/with-stats
                 (table/make-table table cols (mapv #(.toArray ^java.util.ArrayList %) buffers) n))]
       (swap! (:catalog state) catalog/add-table tbl (boolean replace))
       {:table table :row-count n :columns (columns-out (table/columns-json cols))}))))

;; A query result: :columns [{:name :type} …] (canonical type names),
;; :rows a vector of rows (vectors of native values), :row-count.
(defrecord Result [columns rows row-count])

(defn query
  "Executes one SQL statement and returns a Result. opts (all optional, as
  the protocol's query options):
    :threads     worker threads (≥ 1)
    :timeout-ms  0 = none
    :max-rows    more result rows ⇒ RESOURCE_LIMIT
    :mode        \"auto\" | \"row\" | \"vectorized\"; :join \"auto\" | \"hash\" |
                 \"merge\" | \"nested_loop\"; :optimize, :use-indexes,
                 :native (booleans); :result \"count\" (rows not kept)"
  ([db sql] (query db sql {}))
  ([db sql opts]
   (with-engine [state db]
     (let [opened (protocol/open-query state {"op" "query" "sql" sql "options" (options-json opts)}
                                       {:value-fn values/->native})
           {:keys [rows row-count]} (engine/collect opened)]
       (->Result (columns-out (:columns opened)) (mapv vec rows) row-count)))))

(defn columns
  "The result's columns: [{:name :type} …]."
  [^Result result]
  (:columns result))

(defn column-names
  [^Result result]
  (mapv :name (:columns result)))

(defn column-types
  "Canonical type names of the result's columns (\"INT64\", \"DECIMAL(18,2)\", …)."
  [^Result result]
  (mapv :type (:columns result)))

(defn row-count
  ^long [^Result result]
  (:row-count result))

(defn rows
  "The result's rows: a vector of vectors of native values."
  [^Result result]
  (:rows result))

(defn row-maps
  "The result's rows as maps from column name (string) to value."
  [^Result result]
  (let [names (column-names result)]
    (mapv #(zipmap names %) (:rows result))))

(defn save!
  "Saves a table to a PQCF file (path relative to the data directory),
  replacing the file atomically. opts: :row-group-size, :encoding (\"auto\",
  \"plain\", \"dict\" or \"rle\"). Returns {:path p :bytes size}."
  ([db table path] (save! db table path {}))
  ([db table path opts]
   (with-engine [state db]
     (let [resp (request state "save" (cond-> {"table" table "path" path}
                                        (seq opts) (assoc "options" (options-json opts))))]
       {:path (get resp "path") :bytes (get resp "bytes")}))))

(defn open!
  "Opens a PQCF file (path relative to the data directory) as a table,
  recreating its indexes. opts: :replace (default false), :mmap (default
  false), :layout. Returns the same as load!."
  ([db table path] (open! db table path {}))
  ([db table path opts]
   (with-engine [state db]
     (let [options (options-json (dissoc opts :replace))]
       (table-info (request state "open" (cond-> {"table" table "path" path}
                                           (seq options) (assoc "options" options)
                                           (contains? opts :replace) (assoc "replace" (:replace opts)))))))))

(defn drop!
  "Drops a table (NOT_FOUND if there is none). Returns nil."
  [db table]
  (with-engine [state db]
    (request state "drop" {"table" table})
    nil))

(defn tables
  "The tables, sorted by name: [{:name n :row-count c} …]."
  [db]
  (with-engine [state db]
    (mapv (fn [{:strs [name row_count]}] {:name name :row-count row_count})
          (get (request state "tables" {}) "tables"))))

(defn schema
  "A table's schema: {:table :row-count :columns [{:name :type} …]
  :indexes [{:name :column :kind} …] :layout}. NOT_FOUND if there is no
  such table."
  [db table]
  (with-engine [state db]
    (let [resp (request state "schema" {"table" table})]
      {:table (get resp "table")
       :row-count (get resp "row_count")
       :columns (columns-out (get resp "columns"))
       :indexes (mapv (fn [{:strs [name column kind]}] {:name name :column column :kind kind})
                      (get resp "indexes"))
       :layout (keyword (get resp "layout"))})))

(defn version
  "The engine's version information (protocol `version`)."
  []
  (dissoc (protocol/version-info) "ok"))
