(ns polyquery.exec.sort
  "Sorting of materialized rows for ORDER BY (spec/sql/semantics.md §6).

  The sort keys are first extracted column-wise into primitive arrays
  (long[]/double[] plus a null mask, or Object[] for strings and booleans),
  so comparisons read compact arrays instead of chasing row tuples and boxed
  values. Rows are then ordered through a permutation of row indices:
    * one INT64/DECIMAL/DATE/TIMESTAMP key: LSD radix sort (8 bits per pass,
      passes whose digit is constant are skipped) of order-preserving
      unsigned encodings — O(n), branch-free, sequential memory access;
    * otherwise: merge sort of the index array with a typed comparator,
      sorted in parallel chunks that are merged pairwise.
  Ties are broken by input position, i.e. the sort is stable: rows with
  equal keys keep their input order, as with the row engine's sort."
  (:require [polyquery.exec.context :as ctx]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.util ArrayList Comparator List)))

(set! *warn-on-reflection* true)

(definterface IndexComparator
  (^long compareIdx [^long a ^long b] "Order of rows a and b (never 0 for a ≠ b)."))

;; ---------------------------------------------------------------------------
;; Key extraction

(defn- long-kind? [type] (t/long-repr? type))

(defn- extract
  "Typed column of sort key `index` over the rows: [values nulls]."
  [^objects rows ^long n ^long index type]
  (let [nulls (boolean-array n)]
    (case (if (long-kind? type) :long (t/kind type))
      :long
      (let [vals (long-array n)]
        (dotimes [r n]
          (let [x (aget ^objects (aget rows r) index)]
            (if (nil? x) (aset nulls r true) (aset vals r (long x)))))
        [vals nulls])
      :float64
      (let [vals (double-array n)]
        (dotimes [r n]
          (let [x (aget ^objects (aget rows r) index)]
            (if (nil? x) (aset nulls r true) (aset vals r (double x)))))
        [vals nulls])
      (let [vals (object-array n)]
        (dotimes [r n]
          (let [x (aget ^objects (aget rows r) index)]
            (if (nil? x) (aset nulls r true) (aset vals r x))))
        [vals nulls]))))

(defn- key-comparator
  "IndexComparator of one sort key, without the final tie-break."
  [^objects rows n {:keys [index type desc? nulls-first?]}]
  (let [[vals ^booleans nulls] (extract rows n index type)
        sign (if desc? -1 1)
        null-first (if nulls-first? -1 1)
        nulls-cmp (fn ^long [^long a ^long b]
                    (let [x (aget nulls a) y (aget nulls b)]
                      (cond (and x y) 0 x null-first y (- null-first) :else 2)))]
    (case (if (long-kind? type) :long (t/kind type))
      :long
      (let [^longs vals vals]
        (reify IndexComparator
          (compareIdx [_ a b]
            (let [c (long (nulls-cmp a b))]
              (if (== c 2) (* sign (Long/compare (aget vals a) (aget vals b))) c)))))
      :float64
      (let [^doubles vals vals]
        (reify IndexComparator
          (compareIdx [_ a b]
            (let [c (long (nulls-cmp a b))]
              (if (== c 2)
                (let [x (aget vals a) y (aget vals b)]
                  (* sign (cond (< x y) -1 (> x y) 1 :else 0)))
                c)))))
      (let [^objects vals vals
            ^Comparator cmp (v/value-comparator type)]
        (reify IndexComparator
          (compareIdx [_ a b]
            (let [c (long (nulls-cmp a b))]
              (if (== c 2) (* sign (Integer/signum (.compare cmp (aget vals a) (aget vals b)))) c))))))))

(defn- index-comparator
  "Comparator of row indices by all keys, ties by index (stability)."
  ^polyquery.exec.sort.IndexComparator [rows n keys]
  (let [^objects cs (into-array IndexComparator (map #(key-comparator rows n %) keys))
        k (alength cs)]
    (reify IndexComparator
      (compareIdx [_ a b]
        (loop [i 0]
          (if (< i k)
            (let [r (.compareIdx ^IndexComparator (aget cs i) a b)]
              (if (zero? r) (recur (inc i)) r))
            (Long/compare a b)))))))

;; ---------------------------------------------------------------------------
;; Merge sort of index arrays

(defn- insertion-sort! [^ints a ^long lo ^long hi ^IndexComparator c]
  (loop [i (inc lo)]
    (when (< i hi)
      (let [x (aget a i)]
        (loop [j (dec i)]
          (if (and (>= j lo) (pos? (.compareIdx c (aget a j) x)))
            (do (aset a (inc j) (aget a j)) (recur (dec j)))
            (aset a (inc j) x))))
      (recur (inc i)))))

(defn- merge-runs!
  "Merges src[lo, mid) and src[mid, hi) into dst[lo, hi)."
  [^ints src ^ints dst lo mid hi ^IndexComparator c]
  (let [lo (long lo) mid (long mid) hi (long hi)]
    (loop [i lo j mid k lo]
    (when (< k hi)
      (if (and (< i mid) (or (>= j hi) (<= (.compareIdx c (aget src i) (aget src j)) 0)))
        (do (aset dst k (aget src i)) (recur (inc i) j (inc k)))
        (do (aset dst k (aget src j)) (recur i (inc j) (inc k))))))))

(defn- merge-sort!
  "Sorts a[lo, hi) (tmp: scratch of the same length) — bottom-up merge sort
  over insertion-sorted runs of 32. Returns the array holding the result
  (a or tmp)."
  ^ints [^ints a ^ints tmp lo hi ^IndexComparator c]
  (let [lo (long lo) hi (long hi)]
  (loop [s lo]
    (when (< s hi)
      (insertion-sort! a s (min hi (+ s 32)) c)
      (recur (+ s 32))))
  (loop [width 32 ^ints src a ^ints dst tmp]
    (if (>= width (- hi lo))
      src
      (do (loop [s lo]
            (when (< s hi)
              (let [mid (min hi (+ s width))
                    e (min hi (+ s (* 2 width)))]
                (merge-runs! src dst s mid e c)
                (recur e))))
          (recur (* 2 width) dst src))))))

(defn- parallel-merge-sort
  "Sorted permutation of 0..n-1: chunks sorted by `run-all` (a function
  running thunks in parallel), then merged pairwise."
  ^ints [n ^IndexComparator c run-all parts qctx]
  (let [n (long n)
        a (int-array n)
        tmp (int-array n)
        parts (max 1 (min parts (quot n 32768)))
        bounds (vec (for [i (range (inc parts))] (quot (* i n) parts)))]
    (dotimes [i n] (aset a i i))
    (let [_ (run-all (for [i (range parts)]
                            #(let [lo (long (nth bounds i)) hi (long (nth bounds (inc i)))]
                               (ctx/check! qctx)
                               (let [^ints r (merge-sort! a tmp lo hi c)]
                                 ;; leave every sorted chunk in `a`
                                 (when-not (identical? r a) (System/arraycopy r lo a lo (- hi lo)))
                                 nil))))]
      (loop [runs (mapv (fn [i] [(nth bounds i) (nth bounds (inc i))]) (range parts))
             ^ints src a ^ints dst tmp]
        (ctx/check! qctx)
        (if (<= (count runs) 1)
          src
          (let [pairs (partition-all 2 runs)]
            (run-all (for [[[lo mid] [_ hi]] pairs]
                       #(if hi
                          (merge-runs! src dst lo mid hi c)
                          (System/arraycopy src (int lo) dst (int lo) (int (- (long mid) (long lo)))))))
            (recur (mapv (fn [[[lo mid] [_ hi]]] [lo (or hi mid)]) pairs) dst src)))))))

;; ---------------------------------------------------------------------------
;; Radix sort of one integer-like key

(defn- radix-order
  "Stable order of the indices `idx` by unsigned 64-bit keys `ks` (both of
  length m): LSD radix sort, 8 bits per pass."
  ^ints [^longs ks ^ints idx qctx]
  (let [m (alength ks)
        ks2 (long-array m)
        idx2 (int-array m)
        counts (int-array 256)]
    (loop [shift 0 ^longs ks ks ^ints idx idx ^longs ks2 ks2 ^ints idx2 idx2]
      (if (>= shift 64)
        idx
        (do
          (ctx/check! qctx)
          (java.util.Arrays/fill counts 0)
          (dotimes [i m]
            (let [d (bit-and (unsigned-bit-shift-right (aget ks i) shift) 0xFF)]
              (aset counts d (inc (aget counts d)))))
          (if (some #(= m %) counts)
            ;; constant digit: the pass would not change the order
            (recur (+ shift 8) ks idx ks2 idx2)
            (do
              (loop [d 0 total 0]
                (when (< d 256)
                  (let [c (aget counts d)]
                    (aset counts d (int total))
                    (recur (inc d) (+ total c)))))
              (dotimes [i m]
                (let [k (aget ks i)
                      d (bit-and (unsigned-bit-shift-right k shift) 0xFF)
                      pos (aget counts d)]
                  (aset counts d (inc pos))
                  (aset ks2 pos k)
                  (aset idx2 pos (aget idx i))))
              (recur (+ shift 8) ks2 idx2 ks idx))))))))

(defn- radix-sort
  "Sorted permutation of the rows by one integer-like key."
  ^ints [^objects rows ^long n {:keys [index desc? nulls-first?]} qctx]
  (let [index (long index)
        nn (loop [r 0 c 0]
             (if (< r n)
               (recur (inc r) (if (nil? (aget ^objects (aget rows r) index)) c (inc c)))
               c))
        ks (long-array nn)
        idx (int-array nn)
        nulls (int-array (- n nn))]
    (loop [r 0 j 0 z 0]
      (when (< r n)
        (let [x (aget ^objects (aget rows r) index)]
          (if (nil? x)
            (do (aset nulls z (int r)) (recur (inc r) j (inc z)))
            (let [k (long x)
                  k (if desc? (bit-not k) k)]
              ;; flipping the sign bit maps signed order to unsigned order
              (aset ks j (bit-xor k Long/MIN_VALUE))
              (aset idx j (int r))
              (recur (inc r) (inc j) z))))))
    (let [^ints sorted (radix-order ks idx qctx)
          out (int-array n)]
      (if nulls-first?
        (do (System/arraycopy nulls 0 out 0 (alength nulls))
            (System/arraycopy sorted 0 out (alength nulls) nn))
        (do (System/arraycopy sorted 0 out 0 nn)
            (System/arraycopy nulls 0 out nn (alength nulls))))
      out)))

(defn long-order
  "Stable ascending permutation of signed long keys (radix sort)."
  ^ints [^longs ks qctx]
  (let [n (alength ks)
        us (long-array n)
        idx (int-array n)]
    (dotimes [i n]
      (aset us i (bit-xor (aget ks i) Long/MIN_VALUE))
      (aset idx i (int i)))
    (radix-order us idx qctx)))

;; ---------------------------------------------------------------------------

(defn sort-rows
  "The rows (a java.util.List of Object arrays) sorted by `keys` (ORDER BY
  semantics, stable), as a List. `run-all` runs thunks (in parallel for
  `parts` > 1)."
  ^List [^List rows keys qctx run-all parts]
  (let [^objects arr (.toArray rows)
        n (alength arr)
        ^ints order (if (and (= 1 (count keys)) (long-kind? (:type (first keys))))
                      (radix-sort arr n (first keys) qctx)
                      (parallel-merge-sort n (index-comparator arr n keys) run-all (long parts) qctx))
        out (object-array n)]
    (dotimes [i n] (aset out i (aget arr (aget order i))))
    (java.util.Arrays/asList out)))
