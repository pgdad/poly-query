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
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.util ArrayList Comparator List)))

(set! *warn-on-reflection* true)

(definterface IndexComparator
  (^long compareIdx [^long a ^long b] "Order of rows a and b (never 0 for a ≠ b)."))

;; ---------------------------------------------------------------------------
;; Key extraction

(defn- long-kind? [type] (t/long-repr? type))

(def ^:private ^:const kind-long 0)
(def ^:private ^:const kind-double 1)
(def ^:private ^:const kind-string 2)
(def ^:private ^:const kind-other 3)

(defn- key-kind ^long [type]
  (cond (long-kind? type) kind-long
        (= :float64 (t/kind type)) kind-double
        (= :string (t/kind type)) kind-string
        :else kind-other))

(defn- new-key-array [^long kind ^long n]
  (case kind 0 (long-array n) 1 (double-array n) (object-array n)))

(declare utf8-prefix)

(defn- extract!
  "Fills the typed key arrays (values, NULL flags, string prefixes) of sort
  key `index` for rows [lo, hi)."
  [^objects rows index kind vals ^booleans nulls ^longs prefixes lo hi]
  (let [index (long index) kind (long kind) lo (long lo) hi (long hi)]
    (case kind
      0 (let [^longs vals vals]
          (loop [r lo]
            (when (< r hi)
              (let [x (aget ^objects (aget rows r) index)]
                (if (nil? x) (aset nulls r true) (aset vals r (long x))))
              (recur (inc r)))))
      1 (let [^doubles vals vals]
          (loop [r lo]
            (when (< r hi)
              (let [x (aget ^objects (aget rows r) index)]
                (if (nil? x) (aset nulls r true) (aset vals r (double x))))
              (recur (inc r)))))
      (let [^objects vals vals]
        (loop [r lo]
          (when (< r hi)
            (let [x (aget ^objects (aget rows r) index)]
              (if (nil? x)
                (aset nulls r true)
                (do (aset vals r x)
                    (when prefixes (aset prefixes r (long (utf8-prefix x)))))))
            (recur (inc r))))))))

(defn- utf8-prefix
  "Order-preserving 64-bit prefix of s: its first 8 UTF-8 bytes, big-endian
  and zero-padded. UTF-8 byte order is code point order, so where the
  prefixes of two strings differ, their unsigned order is the strings'
  order. -1 (no UTF-8 sequence starts with 0xFF) when a surrogate occurs
  before the 8 bytes are filled: such strings are always compared in full."
  ^long [^String s]
  (let [n (.length s)]
    (loop [i 0 acc 0 nb 0]
      (cond
        (== nb 8) acc
        (== i n) (bit-shift-left acc (* 8 (- 8 nb)))
        :else
        (let [c (long (int (.charAt s i)))]
          (if (and (>= c 0xD800) (<= c 0xDFFF))
            -1
            (let [len (long (cond (< c 0x80) 1 (< c 0x800) 2 :else 3))
                  enc (long (case len
                        1 c
                        2 (bit-or 0xC080 (bit-shift-left (bit-and c 0x7C0) 2) (bit-and c 0x3F))
                        (bit-or 0xE08080 (bit-shift-left (bit-and c 0xF000) 4)
                                (bit-shift-left (bit-and c 0xFC0) 2) (bit-and c 0x3F))))
                  k (min len (- 8 nb))]
              (recur (inc i)
                     (bit-or (bit-shift-left acc (* 8 k)) (unsigned-bit-shift-right enc (* 8 (- len k))))
                     (+ nb k)))))))))

(defn- compare-strings
  "Order of the strings of rows a and b: by their UTF-8 prefixes where these
  decide, else in full."
  ^long [^longs prefixes ^objects strings ^long a ^long b]
  (let [pa (aget prefixes a)
        pb (aget prefixes b)]
    (if (or (== pa pb) (== pa -1) (== pb -1))
      (let [^String sa (aget strings a) ^String sb (aget strings b)]
        (if (identical? sa sb) 0 (text/compare-code-points sa sb)))
      (long (Long/compareUnsigned pa pb)))))

(defn- compare-doubles ^long [^doubles v ^long a ^long b]
  (let [x (aget v a) y (aget v b)]
    (if (< x y) -1 (if (> x y) 1 0))))

(deftype SortKeys [^ints kinds ^objects vals ^objects prefixes ^objects nulls
                   ^longs signs ^longs null-firsts ^objects comparators]
  ;; One comparator class for every key combination, comparing the typed key
  ;; arrays inline (a switch per key instead of a megamorphic call per key),
  ;; ties broken by row index (stability).
  IndexComparator
  (compareIdx [_ a b]
    (let [nk (alength kinds)]
      (loop [i 0]
        (if (< i nk)
          (let [^booleans nl (aget nulls i)
                x-null (if (nil? nl) false (aget nl a))
                y-null (if (nil? nl) false (aget nl b))]
            ;; `if` rather than `cond`: cond's implicit nil else would box
            (if x-null
              (if y-null (recur (inc i)) (aget null-firsts i))
              (if y-null
                (- (aget null-firsts i))
                (let [v (aget vals i)
                    c (case (aget kinds i)
                        0 (long (Long/compare (aget ^longs v a) (aget ^longs v b)))
                        1 (compare-doubles v a b)
                        2 (compare-strings (aget prefixes i) v a b)
                        (long (Integer/signum (.compare ^Comparator (aget comparators i)
                                                        (aget ^objects v a) (aget ^objects v b)))))]
                  (if (zero? c) (recur (inc i)) (if (pos? (aget signs i)) c (- c)))))))
          (long (Long/compare a b)))))))

(defn- any-true? [^booleans a]
  (loop [i 0] (cond (== i (alength a)) false (aget a i) true :else (recur (inc i)))))

(defn- index-comparator
  "Comparator of row indices by all keys, ties by index (stability). The
  key arrays are extracted from the rows in `parts` parallel chunks."
  ^polyquery.exec.sort.IndexComparator [^objects rows n keys run-all parts]
  (let [n (long n)
        k (count keys)
        keys (vec keys)
        kinds (int-array (map #(key-kind (:type %)) keys))
        vals (object-array (map-indexed (fn [i _] (new-key-array (aget kinds i) n)) keys))
        prefixes (object-array (map-indexed (fn [i _] (when (== kind-string (aget kinds i)) (long-array n))) keys))
        nulls (object-array (repeatedly k #(boolean-array n)))
        parts (max 1 (min (long parts) (quot n 16384)))]
    (run-all (for [p (range parts)]
               #(let [lo (quot (* (long p) n) parts)
                      hi (quot (* (inc (long p)) n) parts)]
                  (dotimes [i k]
                    (extract! rows (long (:index (keys i))) (aget kinds i) (aget vals i) (aget nulls i)
                              (aget prefixes i) lo hi)))))
    (dotimes [i k]
      (when-not (any-true? (aget nulls i)) (aset nulls i nil)))
    (SortKeys. kinds vals prefixes nulls
               (long-array (map #(if (:desc? %) -1 1) keys))
               (long-array (map #(if (:nulls-first? %) -1 1) keys))
               (object-array (map #(when (== kind-other (key-kind (:type %))) (v/value-comparator (:type %)))
                                  keys)))))

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

(defn- merge-ranges!
  "Merges the sorted ranges src[a, a-end) and src[b, b-end) into dst from
  position k on (ties, which the comparator never reports for distinct rows,
  would go to the first range)."
  [^ints src ^ints dst a a-end b b-end k ^IndexComparator c]
  (let [a-end (long a-end) b-end (long b-end)]
    (loop [i (long a) j (long b) k (long k)]
      (cond
        (< i a-end)
        (if (or (>= j b-end) (<= (.compareIdx c (aget src i) (aget src j)) 0))
          (do (aset dst k (aget src i)) (recur (inc i) j (inc k)))
          (do (aset dst k (aget src j)) (recur i (inc j) (inc k))))
        (< j b-end) (System/arraycopy src (int j) dst (int k) (int (- b-end j)))))))

(defn- merge-runs!
  "Merges src[lo, mid) and src[mid, hi) into dst[lo, hi)."
  [^ints src ^ints dst lo mid hi ^IndexComparator c]
  (merge-ranges! src dst lo mid mid hi lo c))

(defn- merge-split
  "Merge path: how many elements of the run src[lo, mid) are among the
  first k elements of the merge of src[lo, mid) and src[mid, hi)."
  [^ints src lo mid hi k ^IndexComparator c]
  (let [lo (long lo) mid (long mid) hi (long hi) k (long k)]
  (loop [l (max 0 (- k (- hi mid))) h (min k (- mid lo))]
    (if (< l h)
      (let [i (quot (+ l h) 2)
            j (- k i)]
        ;; i elements of the first run are too few when its next element
        ;; precedes the last element taken from the second run
        (if (neg? (.compareIdx c (aget src (+ lo i)) (aget src (+ mid (dec j)))))
          (recur (inc i) h)
          (recur l i)))
      l))))

(defn- merge-tasks
  "Thunks merging src[lo, mid) and src[mid, hi) into dst[lo, hi) in `pieces`
  independent output slices (split points found by binary search)."
  [^ints src ^ints dst lo mid hi pieces ^IndexComparator c]
  (let [lo (long lo) mid (long mid) hi (long hi) pieces (long pieces)
        n (- hi lo)
        ks (mapv (fn [^long p] (quot (* p n) pieces)) (range (inc pieces)))]
    (for [p (range pieces)]
      (fn []
        (let [k0 (long (ks p))
              k1 (long (ks (inc (long p))))
              i0 (long (merge-split src lo mid hi k0 c))
              i1 (long (merge-split src lo mid hi k1 c))]
          (merge-ranges! src dst (+ lo i0) (+ lo i1) (+ mid (- k0 i0)) (+ mid (- k1 i1)) (+ lo k0) c))))))

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
        parts (max 1 (min (long parts) (quot n 32768)))
        bounds (vec (for [^long i (range (inc parts))] (quot (* i n) parts)))]
    (dotimes [i n] (aset a i i))
    (let [_ (run-all (for [^long i (range parts)]
                            #(let [lo (long (nth bounds i)) hi (long (nth bounds (inc i)))]
                               (ctx/check! qctx)
                               (let [^ints r (merge-sort! a tmp lo hi c)]
                                 ;; leave every sorted chunk in `a`
                                 (when-not (identical? r a) (System/arraycopy r lo a lo (- hi lo)))
                                 nil))))]
      (loop [runs (mapv (fn [^long i] [(nth bounds i) (nth bounds (inc i))]) (range parts))
             ^ints src a ^ints dst tmp]
        (ctx/check! qctx)
        (if (<= (count runs) 1)
          src
          (let [pairs (partition-all 2 runs)
                ;; every level keeps all `parts` workers busy: each pair's
                ;; merge is split into equal output slices
                pieces (max 1 (quot (+ parts (dec (count pairs))) (count pairs)))]
            (run-all (mapcat (fn [[[lo mid] [_ hi]]]
                               (if hi
                                 (merge-tasks src dst lo mid hi pieces c)
                                 [#(System/arraycopy src (int lo) dst (int lo) (int (- (long mid) (long lo))))]))
                             pairs))
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
        nn (long (loop [r 0 c 0]
                   (if (< r n)
                     (recur (inc r) (if (nil? (aget ^objects (aget rows r) index)) c (inc c)))
                     c)))
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
                      (parallel-merge-sort n (index-comparator arr n keys run-all parts) run-all (long parts) qctx))
        out (object-array n)]
    (dotimes [i n] (aset out i (aget arr (aget order i))))
    (java.util.Arrays/asList out)))
