(ns polyquery.storage.table
  "Immutable in-memory tables. Data is stored column-wise: one Object array
  per column holding runtime values (see polyquery.types)."
  (:require [polyquery.types :as t]
            [polyquery.util.text :as text]))

(set! *warn-on-reflection* true)

(defrecord Column [name type])

(defrecord Table [name columns data ^long row-count])

(defn make-table
  "columns: seq of Column; data: seq of Object arrays (one per column)."
  [name columns data row-count]
  (->Table name (vec columns) (vec data) (long row-count)))

(defn column-index
  "Index of the column named (case-insensitively) `cname`, or nil."
  [table ^String cname]
  (let [k (text/ascii-lower cname)]
    (first (keep-indexed (fn [i c] (when (= k (text/ascii-lower (:name c))) i))
                         (:columns table)))))

(defn column-array ^objects [table ^long i]
  (nth (:data table) i))

(defn columns-json
  [columns]
  (mapv (fn [c] {"name" (:name c) "type" (t/type-name (:type c))}) columns))
