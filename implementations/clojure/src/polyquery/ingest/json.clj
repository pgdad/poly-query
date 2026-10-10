(ns polyquery.ingest.json
  "JSON array and JSON Lines loading (ingestion.md §2)."
  (:require [clojure.string :as str]
            [polyquery.ingest.common :as c]
            [polyquery.storage.table :as table]
            [polyquery.types :as t]
            [polyquery.util.json :as json]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.io BufferedReader Reader)
           (java.util ArrayList LinkedHashMap)
           (polyquery.util.json JsonNumber)))

(set! *warn-on-reflection* true)

(defn- object-pairs
  "object-fn for ingestion: keeps key order and rejects duplicate keys."
  [pairs]
  (let [seen (java.util.HashSet.)]
    (doseq [[k _] pairs]
      (when-not (.add seen k)
        (c/ingest-error! (str "duplicate key '" k "' in JSON object"))))
    {::pairs pairs}))

(defn- parse-json [^String s what]
  (try
    (json/read-str s {:number-fn json/ingest-number :object-fn object-pairs})
    (catch clojure.lang.ExceptionInfo e
      (if (json/syntax-error? e)
        (c/ingest-error! (str "malformed " what ": " (.getMessage e) " at offset " (:pos (ex-data e))))
        (throw e)))))

(defn- check-value! [record k x]
  (cond
    (or (map? x) (vector? x))
    (c/ingest-error! (str "record " record ": nested value for key '" k "'") {"record" record})
    (and (string? x) (> (.length ^String x) c/max-field-chars))
    (c/ingest-error! (str "record " record ": field longer than 16 MiB") {"record" record})))

(defn- collect
  "Collects objects (each {::pairs [[k v] ...]}) into column buffers keyed by
  exact key in first-appearance order. Returns [keys buffers row-count]."
  [objects limits]
  (let [index (LinkedHashMap.)
        cols (ArrayList.)
        nrows (long (count objects))]
    (c/check-row-limit! nrows limits)
    (doseq [[row obj] (map-indexed vector objects)]
      (when-not (and (map? obj) (contains? obj ::pairs))
        (c/ingest-error! (str "record " (inc row) " is not a JSON object") {"record" (inc row)}))
      (doseq [[k x] (::pairs obj)]
        (check-value! (inc row) k x)
        (let [ci (or (.get index k)
                     (let [buf (object-array nrows)]
                       (.put index k (.size cols))
                       (.add cols buf)
                       (dec (.size cols))))]
          (aset ^objects (.get cols (int ci)) (int row) x))))
    [(vec (.keySet index)) (vec cols) nrows]))

(defn- category [x]
  (cond (instance? Boolean x) :boolean
        (instance? JsonNumber x) :number
        (string? x) :string))

(defn- infer-type
  [^objects vals column-name]
  (let [cats (into #{} (keep category) vals)]
    (when (> (count cats) 1)
      (c/ingest-error! (str "column '" column-name "' mixes JSON types "
                            (str/join ", " (map name cats)))))
    (case (first cats)
      nil :string
      :boolean :boolean
      :number (if (every? (fn [x] (or (nil? x)
                                      (and (.-integral? ^JsonNumber x)
                                           (instance? Long (v/parse-int64 (str x))))))
                          vals)
                :int64
                :float64)
      :string (let [strs (remove nil? vals)]
                (cond
                  (every? #(v/parse-date %) strs) :date
                  (every? #(v/parse-timestamp % true) strs) :timestamp
                  :else :string)))))

(defn- convert-value
  "Converts one JSON value to the target type (explicit schema rules, which
  also cover inferred types)."
  [x type record column-name]
  (let [fail #(c/conversion-error! record column-name x type)]
    (cond
      (nil? x) nil
      (instance? Boolean x) (if (= type :boolean) x (fail))
      (instance? JsonNumber x)
      (if (contains? #{:int64 :float64 :decimal} (t/kind type))
        (let [r ((c/text-parser type) (str x))]
          (if (identical? r ::c/invalid) (fail) r))
        (fail))
      (string? x)
      (case (t/kind type)
        :string x
        :boolean (fail)
        (let [s (text/trim-blank x)
              r (if (.isEmpty s) ::c/invalid ((c/text-parser type) s))]
          (if (identical? r ::c/invalid) (fail) r))))))

(defn- build-table
  [name objects schema limits]
  (let [[ks cols nrows] (collect objects limits)
        nrows (long nrows)]
    (if schema
      (let [by-name (into {} (map-indexed (fn [i col] [(text/ascii-lower (:name col)) i]) schema))
            _ (c/validate-column-names! (map :name schema))
            data (vec (repeatedly (count schema) #(object-array nrows)))]
        (doseq [[k ^objects src] (map vector ks cols)]
          (let [ci (or (by-name (text/ascii-lower k))
                       (c/ingest-error! (str "key '" k "' is not in the schema")))
                col (nth schema ci)
                ^objects dst (nth data ci)]
            (dotimes [r nrows]
              (let [x (aget src r)]
                (when (some? x)
                  (when (some? (aget dst r))
                    (c/ingest-error! (str "record " (inc r) ": duplicate key '" k "'")))
                  (aset dst r (convert-value x (:type col) (inc r) (:name col))))))))
        (table/make-table name schema data nrows))
      (do
        (c/validate-column-names! ks)
        (let [types (mapv infer-type cols ks)
              data (mapv (fn [^objects src type k]
                           (let [dst (object-array nrows)]
                             (dotimes [r nrows]
                               (aset dst r (convert-value (aget src r) type (inc r) k)))
                             dst))
                         cols types ks)]
          (table/make-table name (c/make-columns ks types) data nrows))))))

(defn load-json
  [^Reader reader {:keys [name schema limits]}]
  (let [doc (parse-json (slurp reader) "JSON")]
    (when-not (vector? doc)
      (c/ingest-error! "JSON document must be an array of objects"))
    (build-table name doc schema limits)))

(defn load-jsonl
  [^Reader reader {:keys [name schema limits]}]
  (let [br (BufferedReader. reader)
        objects (loop [acc (transient []) line-no 1]
                  (if-let [line (.readLine br)]
                    (let [trimmed (str/trim line)]
                      (if (empty? trimmed)
                        (recur acc (inc line-no))
                        (let [obj (parse-json trimmed (str "JSON on line " line-no))]
                          (when-not (and (map? obj) (contains? obj ::pairs))
                            (c/ingest-error! (str "line " line-no " is not a JSON object") {"line" line-no}))
                          (recur (conj! acc obj) (inc line-no)))))
                    (persistent! acc)))]
    (build-table name objects schema limits)))
