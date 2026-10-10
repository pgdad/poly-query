(ns polyquery.storage.table
  "Immutable tables (spec/storage/indexes-and-planning.md §1).

  A table's rows are split into *segments* (one for in-memory tables, one per
  row group for PQCF-backed tables). A segment holds one ColumnVector per
  column — or a delay producing it, for lazily decoded memory-mapped chunks —
  and optional per-column chunk statistics used for row-group skipping.

  Layouts:
    :column  typed vectors with validity bitmaps (STRING columns dictionary
             encoded when beneficial or forced)
    :row     an array of row tuples (Object arrays); columns are RowView
             views over it
  Both are read through the same ColumnVector interface, so query results do
  not depend on the layout.

  Tables also carry their indexes (polyquery.storage.index) and lazily
  computed per-column statistics (polyquery.storage.stats)."
  (:require [polyquery.storage.column :as col]
            [polyquery.types :as t]
            [polyquery.util.text :as text])
  (:import (polyquery.storage.column ColumnVector RowView)))

(set! *warn-on-reflection* true)

(defrecord Column [name type])

;; vectors: per column a ColumnVector or an IDeref yielding one.
;; chunk-stats: nil or per column nil | {:min v :max v :null-count n}.
(defrecord Segment [^long start ^long row-count vectors chunk-stats])

;; layout: :row | :column; indexes: vector of index maps; stats: per column
;; a delay of the column statistics (attached by polyquery.storage.stats).
(defrecord Table [name columns ^long row-count layout segments indexes stats])

(defn segment-vector
  "The ColumnVector of column i in segment seg (forcing lazy decoding)."
  ^polyquery.storage.column.ColumnVector [seg ^long i]
  (let [v (nth (:vectors seg) i)]
    (if (instance? ColumnVector v) v @v)))

(defn- rows-of
  "Row tuples (an Object array of Object arrays) from column arrays."
  ^objects [data ^long n]
  (let [^objects cols (into-array Object data)
        ncols (alength cols)
        rows (object-array n)]
    (dotimes [r n]
      (let [row (object-array ncols)]
        (dotimes [c ncols] (aset row c (aget ^objects (aget cols c) r)))
        (aset rows r row)))
    rows))

(defn in-memory-segment
  "A single segment holding column arrays `data` in the given layout."
  [columns data ^long n {:keys [layout dictionary] :or {layout :column dictionary :auto}}]
  (let [vectors (case layout
                  :row (let [rows (rows-of data n)]
                         (mapv (fn [i] (RowView. rows i)) (range (count columns))))
                  :column (mapv (fn [c vals] (col/from-objects (:type c) vals dictionary))
                                columns data))]
    (->Segment 0 n vectors nil)))

(defn make-table
  "A table from column arrays. columns: seq of Column; data: seq of Object
  arrays (one per column); opts: {:layout :row|:column, :dictionary
  true|false|:auto}."
  ([name columns data row-count] (make-table name columns data row-count {}))
  ([name columns data row-count opts]
   (let [layout (or (:layout opts) :column)]
     (->Table name (vec columns) (long row-count) layout
              [(in-memory-segment columns data row-count (assoc opts :layout layout))]
              [] nil))))

(defn column-index
  "Index of the column named (case-insensitively) `cname`, or nil."
  [table ^String cname]
  (let [k (text/ascii-lower cname)]
    (first (keep-indexed (fn [i c] (when (= k (text/ascii-lower (:name c))) i))
                         (:columns table)))))

(defn column-array
  "All values of column i as an Object array (reads every segment)."
  ^objects [table ^long i]
  (let [out (object-array (:row-count table))]
    (doseq [seg (:segments table)]
      (let [^ColumnVector v (segment-vector seg i)
            start (long (:start seg))]
        (dotimes [r (:row-count seg)]
          (aset out (+ start r) (.valueAt v r)))))
    out))

(defn segment-index
  "Index of the segment containing row id r (binary search on starts)."
  ^long [table ^long r]
  (let [segs (:segments table)]
    (loop [lo 0 hi (dec (count segs))]
      (if (>= lo hi)
        lo
        (let [mid (unsigned-bit-shift-right (+ lo hi 1) 1)]
          (if (<= (long (:start (nth segs mid))) r)
            (recur mid hi)
            (recur lo (dec mid))))))))

(defn dictionary-columns
  "Names of the columns stored dictionary-encoded (realized vectors only)."
  [table]
  (let [seg (first (:segments table))]
    (vec (for [i (range (count (:columns table)))
               :let [v (when seg (nth (:vectors seg) i))]
               :when (and (instance? ColumnVector v) (col/dictionary-encoded? v))]
           (:name (nth (:columns table) i))))))

(defn columns-json
  [columns]
  (mapv (fn [c] {"name" (:name c) "type" (t/type-name (:type c))}) columns))
