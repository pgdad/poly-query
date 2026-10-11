(ns polyquery.result
  "Result-set serialization (spec/data-types/types.md §9).

  Engine rows (Object[] of runtime values, polyquery.types) are collected
  into a *sink*: JSON values per row (the engine API), JSON text (the
  protocol fast path — each value is appended to one buffer by an encoder
  specialized for its column type, without intermediate strings or arrays),
  or nothing (row counting)."
  (:require [polyquery.types :as t]
            [polyquery.util.json :as json]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(defn json-row-fn
  "Function converting an engine row into an Object[] of JSON values."
  [types]
  (let [types (object-array types)
        ncols (alength types)]
    (fn [^objects row]
      (let [out (object-array ncols)]
        (dotimes [i ncols]
          (aset out i (v/value->json (aget types i) (aget row i))))
        out))))

;; ---------------------------------------------------------------------------
;; JSON text encoders

(definterface ValueEncoder
  (^void encode [^StringBuilder sb v] "Appends the JSON text of a non-NULL value."))

(defn- value-encoder
  ^ValueEncoder [t]
  (case (t/kind t)
    :int64 (reify ValueEncoder (encode [_ sb v] (.append sb (long v))))
    :float64 (reify ValueEncoder (encode [_ sb v] (json/write-double sb (double v))))
    :boolean (reify ValueEncoder (encode [_ sb v] (.append sb (if (boolean v) "true" "false"))))
    :string (reify ValueEncoder (encode [_ sb v] (json/write-string sb v)))
    ;; DECIMAL, DATE and TIMESTAMP are JSON strings; their text needs no escaping
    :decimal (let [s (t/scale t)]
               (reify ValueEncoder
                 (encode [_ sb v] (.append sb \") (v/append-decimal! sb v s) (.append sb \"))))
    :date (reify ValueEncoder
            (encode [_ sb v] (.append sb \") (v/append-date! sb (long v)) (.append sb \")))
    :timestamp (reify ValueEncoder
                 (encode [_ sb v] (.append sb \") (v/append-timestamp! sb (long v)) (.append sb \")))
    (reify ValueEncoder (encode [_ sb v] (json/write-value sb (v/value->json t v))))))

(defn append-row!
  "Appends an engine row as a JSON array, using one encoder per column."
  [^StringBuilder sb ^"[Lpolyquery.result.ValueEncoder;" encoders ^objects row]
  (.append sb \[)
  (dotimes [i (alength encoders)]
    (when (pos? i) (.append sb \,))
    (let [x (aget row i)]
      (if (nil? x)
        (.append sb "null")
        (.encode ^ValueEncoder (aget encoders i) sb x))))
  (.append sb \]))

(defn encoders
  "Array of value encoders for column types."
  ^"[Lpolyquery.result.ValueEncoder;" [types]
  (into-array ValueEncoder (map value-encoder types)))

;; ---------------------------------------------------------------------------
;; Sinks

(defprotocol RowSink
  (accept! [sink row] "Adds an engine row.")
  (rows [sink] "The collected rows."))

(deftype ValuesSink [row-fn ^:unsynchronized-mutable acc]
  RowSink
  (accept! [_ row] (set! acc (conj! acc (row-fn row))))
  (rows [_] (persistent! acc)))

(deftype TextSink [^StringBuilder sb encoders ^:unsynchronized-mutable first?]
  RowSink
  (accept! [_ row]
    (if first? (set! first? false) (.append sb \,))
    (append-row! sb encoders row))
  (rows [_] (json/raw (.append sb \]))))

(deftype CountSink []
  RowSink
  (accept! [_ _row] nil)
  (rows [_] nil))

(defn sink
  "A new sink for rows of the given column types. encoding: :values (rows as
  vectors of JSON values), :json-text (rows as one json/raw array) or :count
  (rows are discarded)."
  [encoding types]
  (case encoding
    :values (ValuesSink. (json-row-fn types) (transient []))
    :json-text (TextSink. (doto (StringBuilder. 65536) (.append \[)) (encoders types) true)
    :count (CountSink.)))
