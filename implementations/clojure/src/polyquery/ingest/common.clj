(ns polyquery.ingest.common
  "Shared ingestion logic: column-name validation, CSV text type inference and
  text → value conversion (spec/data-types/ingestion.md)."
  (:require [polyquery.errors :as err]
            [polyquery.storage.table :as table]
            [polyquery.types :as t]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.util ArrayList List)))

(set! *warn-on-reflection* true)

(def ^:const max-field-chars (* 16 1024 1024))

(defn ingest-error!
  ([msg] (err/fail! "INGEST_ERROR" msg))
  ([msg details] (err/fail! "INGEST_ERROR" msg details)))

(defn validate-column-names!
  [names]
  (when-let [i (first (keep-indexed (fn [i n] (when (empty? n) i)) names))]
    (ingest-error! (str "column " (inc i) " has an empty name")))
  (let [dups (->> names (map text/ascii-lower) frequencies (filter #(> (val %) 1)) keys)]
    (when (seq dups)
      (ingest-error! (str "duplicate column name '" (first dups) "'")))))

(defn check-row-limit!
  [^long rows limits]
  (when (> rows (long (:max-table-rows limits)))
    (err/fail! "RESOURCE_LIMIT" (str "table exceeds the maximum of " (:max-table-rows limits) " rows"))))

;; ---------------------------------------------------------------------------
;; CSV text inference (ingestion.md §1.1)

(def ^:private bit-bool 1)
(def ^:private bit-int 2)
(def ^:private bit-float 4)
(def ^:private bit-date 8)
(def ^:private bit-ts 16)

(defn- text-matches
  "Bitmask of candidate types (among `mask`) matched by trimmed text s."
  ^long [^String s ^long mask]
  (cond-> 0
    (and (pos? (bit-and mask bit-bool)) (some? (v/parse-boolean s))) (bit-or bit-bool)
    (and (pos? (bit-and mask bit-int)) (instance? Long (v/parse-int64 s))) (bit-or bit-int)
    (and (pos? (bit-and mask bit-float)) (instance? Double (v/parse-float64 s))) (bit-or bit-float)
    (and (pos? (bit-and mask (bit-or bit-date bit-ts))) (some? (v/parse-date s)))
    (bit-or (bit-and mask (bit-or bit-date bit-ts)))
    (and (pos? (bit-and mask bit-ts)) (some? (v/parse-timestamp s))) (bit-or bit-ts)))

(defn infer-text-type
  "Infers the type of a CSV column from its raw field values (nil = unquoted
  empty, \"\" = quoted empty)."
  [^List values]
  (let [n (.size values)]
    (loop [i 0 mask 31 considered? false]
      (if (or (= i n) (zero? mask))
        (cond
          (not considered?) :string
          (pos? (bit-and mask bit-bool)) :boolean
          (pos? (bit-and mask bit-int)) :int64
          (pos? (bit-and mask bit-float)) :float64
          (pos? (bit-and mask bit-date)) :date
          (pos? (bit-and mask bit-ts)) :timestamp
          :else :string)
        (let [raw (.get values i)]
          (if (nil? raw)
            (recur (inc i) mask considered?)
            (let [s (text/trim-blank raw)]
              (if (.isEmpty s)
                (recur (inc i) mask considered?)
                (recur (inc i) (bit-and mask (text-matches s mask)) true)))))))))

;; ---------------------------------------------------------------------------
;; Text → value conversion (ingestion.md §1.2)

(defn conversion-error!
  [record column-name raw type]
  (err/fail! "CONVERSION_ERROR"
             (str "record " record ", column '" column-name "': cannot convert '" raw "' to "
                  (t/type-name type))
             {"record" record "column_name" column-name}))

(defn text-parser
  "Returns (fn [trimmed-text]) → value or ::invalid for a non-STRING type."
  [type]
  (case (t/kind type)
    :boolean (fn [s] (let [b (v/parse-boolean s)] (if (nil? b) ::invalid b)))
    :int64 (fn [s] (let [x (v/parse-int64 s)] (if (instance? Long x) x ::invalid)))
    :float64 (fn [s] (let [x (v/parse-float64 s)] (if (instance? Double x) x ::invalid)))
    :decimal (let [p (t/precision type) sc (t/scale type)]
               (fn [s] (let [x (v/parse-decimal-exact s p sc)] (if (nil? x) ::invalid x))))
    :date (fn [s] (or (v/parse-date s) ::invalid))
    :timestamp (fn [s] (or (v/parse-timestamp s true) ::invalid))))

(defn convert-text-column
  "Converts raw CSV field values into an Object array of the given type.
  `record-offset` maps a 0-based row index to its 1-based record number."
  ^objects [^List values type column-name ^long record-offset]
  (let [n (.size values)
        out (object-array n)]
    (if (= type :string)
      (dotimes [i n] (aset out i (.get values i)))
      (let [parse (text-parser type)]
        (dotimes [i n]
          (when-let [raw (.get values i)]
            (let [s (text/trim-blank raw)]
              (when-not (.isEmpty s)
                (let [x (parse s)]
                  (if (identical? x ::invalid)
                    (conversion-error! (+ i record-offset) column-name raw type)
                    (aset out i x)))))))))
    out))

(defn make-columns
  [names types]
  (mapv table/->Column names types))

(defn new-column-buffers
  "A vector of n empty ArrayLists collecting raw column values."
  [^long n]
  (vec (repeatedly n #(ArrayList.))))
