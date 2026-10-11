(ns polyquery.storage.index
  "Single-column secondary indexes (spec/storage/indexes-and-planning.md §2).

  Both kinds are built from a *sorted permutation*: the row ids of the
  non-null values ordered by value (ties by row id), alongside the sorted
  values themselves.
    BTREE  binary search over the sorted values: equality and range lookups
           (an ordered structure equivalent to a B-tree for an immutable table)
    HASH   a hash map from the normalized value to its run [start, end) in
           the permutation: equality lookups
  NULLs are not indexed, so no lookup ever returns them. Lookups return the
  matching row ids in ascending order (i.e. table order).

  An index is a map {:name :column (column name) :column-index :kind
  :hash|:btree :data IndexData}."
  (:require [polyquery.storage.table :as table]
            [polyquery.values :as v])
  (:import (java.util Arrays Comparator HashMap)))

(set! *warn-on-reflection* true)

(defrecord IndexData [^objects keys ^ints row-ids ^long distinct lookup])

(defn- sorted-permutation
  "[sorted non-null values, their row ids] of column i."
  [tbl ^long i type]
  (let [^objects vals (table/column-array tbl i)
        ^Comparator cmp (v/value-comparator type)
        ^"[Ljava.lang.Integer;" ids
        (into-array Integer (eduction (filter #(some? (aget vals (int %))))
                                      (map #(Integer/valueOf (int %)))
                                      (range (alength vals))))]
    (Arrays/sort ids (reify Comparator
                       (compare [_ a b]
                         (let [r (.compare cmp (aget vals (int a)) (aget vals (int b)))]
                           (if (zero? r) (Integer/compare (int a) (int b)) r)))))
    (let [n (alength ids)
          keys (object-array n)
          row-ids (int-array n)]
      (dotimes [k n]
        (let [r (int (aget ids k))]
          (aset row-ids k r)
          (aset keys k (aget vals r))))
      [keys row-ids])))

(defn- runs
  "Calls (f key start end) for each run of equal (normalized) keys."
  [^objects keys f]
  (let [n (alength keys)]
    (loop [start 0]
      (when (< start n)
        (let [k (v/normalize-key (aget keys start))
              end (loop [e (inc start)]
                    (if (and (< e n) (= k (v/normalize-key (aget keys e)))) (recur (inc e)) e))]
          (f k start end)
          (recur (long end)))))))

(defn build
  "Builds index `idx-name` of kind :hash|:btree on column i of a table."
  [tbl idx-name ^long i kind]
  (let [c (nth (:columns tbl) i)
        [^objects keys row-ids] (sorted-permutation tbl i (:type c))
        distinct (volatile! 0)
        lookup (when (= kind :hash) (HashMap.))]
    (runs keys (fn [k start end]
                 (vswap! distinct #(inc (long %)))
                 (when lookup (.put ^HashMap lookup k (long-array [start end])))))
    {:name idx-name :column (:name c) :column-index i :kind kind
     :data (->IndexData keys row-ids @distinct lookup)}))

(defn kind-name [kind] (if (= kind :hash) "HASH" "BTREE"))

(defn parse-kind [^String s]
  (case (.toUpperCase s) "HASH" :hash "BTREE" :btree nil))

;; ---------------------------------------------------------------------------
;; Lookups (return sorted int arrays of row ids)

(defn- ids-of-ranges
  "Sorted, distinct row ids of the permutation ranges [[start end] …]."
  ^ints [^ints row-ids ranges]
  (let [total (reduce + 0 (map (fn [[s e]] (max 0 (- (long e) (long s)))) ranges))
        out (int-array total)]
    (loop [rs ranges pos 0]
      (when-let [[s e] (first rs)]
        (let [len (max 0 (- (long e) (long s)))]
          (System/arraycopy row-ids (int s) out (int pos) (int len))
          (recur (next rs) (+ pos len)))))
    (Arrays/sort out)
    (if (> (count ranges) 1)
      (let [distinct (int-array (alength out))
            n (loop [i 0 k 0]
                (if (< i (alength out))
                  (if (and (pos? i) (= (aget out i) (aget out (dec i))))
                    (recur (inc i) k)
                    (do (aset distinct k (aget out i)) (recur (inc i) (inc k))))
                  k))]
        (Arrays/copyOf distinct (int n)))
      out)))

(defn- lower-bound
  "First position whose key is not below the bound: (cmp key bound) ≥ 0, or
  > 0 when exclusive."
  ^long [^objects keys cmp bound exclusive?]
  (loop [lo 0 hi (alength keys)]
    (if (< lo hi)
      (let [mid (unsigned-bit-shift-right (+ lo hi) 1)
            c (long (cmp (aget keys mid) bound))]
        (if (if exclusive? (> c 0) (>= c 0)) (recur lo mid) (recur (inc mid) hi)))
      lo)))

(defn- range-span
  "[start end) of the keys satisfying all bounds. A bound is {:cmp (fn [key
  value]) → int, :value v, :inclusive? b}."
  [^objects keys lowers uppers]
  (let [start (reduce max 0 (map #(lower-bound keys (:cmp %) (:value %) (not (:inclusive? %))) lowers))
        end (reduce min (alength keys)
                    (map #(lower-bound keys (:cmp %) (:value %) (boolean (:inclusive? %))) uppers))]
    [start (max (long start) (long end))]))

(defn lookup-equal
  "Row ids whose key equals one of `keys` (hash-domain keys, see
  polyquery.values/key-fn) — HASH indexes."
  ^ints [idx keys]
  (let [^IndexData d (:data idx)
        ^HashMap m (:lookup d)]
    (ids-of-ranges (.-row-ids d)
                   (keep (fn [k] (when-let [^longs se (.get m (v/normalize-key k))]
                                   [(aget se 0) (aget se 1)]))
                         (distinct keys)))))

(defn lookup-ranges
  "Row ids whose key lies in one of the ranges [{:lowers [bound] :uppers
  [bound]}] (see range-span) — BTREE indexes."
  ^ints [idx ranges]
  (let [^IndexData d (:data idx)]
    (ids-of-ranges (.-row-ids d)
                   (map #(range-span (.-keys d) (:lowers %) (:uppers %)) ranges))))

(defn distinct-count ^long [idx] (.-distinct ^IndexData (:data idx)))

(defn entry-count ^long [idx] (alength ^objects (.-keys ^IndexData (:data idx))))

(defn smallest-key [idx]
  (let [^objects ks (.-keys ^IndexData (:data idx))] (when (pos? (alength ks)) (aget ks 0))))

(defn largest-key [idx]
  (let [^objects ks (.-keys ^IndexData (:data idx))]
    (when (pos? (alength ks)) (aget ks (dec (alength ks))))))
