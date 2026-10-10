(ns polyquery.errors
  "Engine error model (spec/errors/errors.md).

  Every failure that should reach a client is thrown as an `ex-info` whose
  data carries `:pq/code` (one of the stable error-code strings) and optional
  `:pq/details` (a map serialized as the error's `details` object).")

(def codes
  #{"PARSE_ERROR" "SEMANTIC_ERROR" "TYPE_ERROR" "NUMERIC_OVERFLOW" "DIVISION_BY_ZERO"
    "CONVERSION_ERROR" "INVALID_ARGUMENT" "SUBQUERY_CARDINALITY" "INVALID_REQUEST"
    "INGEST_ERROR" "UNSUPPORTED" "ACCESS_DENIED" "NOT_FOUND" "ALREADY_EXISTS" "CANCELLED"
    "RESOURCE_LIMIT" "IO_ERROR" "STORAGE_CORRUPT" "STORAGE_VERSION_UNSUPPORTED"
    "INTERNAL_ERROR" "OVERLOADED" "SHUTTING_DOWN" "TIMEOUT"})

(defn error
  "Builds (does not throw) an engine error."
  ([code message] (error code message nil))
  ([code message details]
   {:pre [(contains? codes code)]}
   (ex-info message (cond-> {:pq/code code}
                      (seq details) (assoc :pq/details details)))))

(defn fail!
  "Throws an engine error."
  ([code message] (throw (error code message nil)))
  ([code message details] (throw (error code message details))))

(defn error-code
  "Returns the error code of an engine error, or nil for other throwables."
  [t]
  (:pq/code (ex-data t)))

(defn ->error-object
  "Converts any throwable into a protocol error object."
  [^Throwable t]
  (if-let [code (error-code t)]
    (cond-> {"code" code "message" (or (.getMessage t) code)}
      (:pq/details (ex-data t)) (assoc "details" (:pq/details (ex-data t))))
    (cond
      (instance? OutOfMemoryError t)
      {"code" "RESOURCE_LIMIT" "message" "out of memory"}
      (instance? StackOverflowError t)
      {"code" "RESOURCE_LIMIT" "message" "expression or input nesting too deep"}
      :else
      {"code" "INTERNAL_ERROR"
       "message" (str "internal error: " (.getName (class t))
                      (when-let [m (.getMessage t)] (str ": " m)))})))
