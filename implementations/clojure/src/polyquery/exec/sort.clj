(ns polyquery.exec.sort
  "Sorting of materialized rows for ORDER BY (spec/sql/semantics.md §6).

  The sort keys are first extracted column-wise into primitive arrays
  (long[]/double[] plus a null mask, or Object[] for strings and booleans),
  so comparisons read compact arrays instead of chasing row tuples and boxed
  values. Rows are then ordered through a permutation of row indices by an
  MSD sort over the keys:
    * NULLs of the current key are split off (stable partition) to the
      front or the back;
    * the other rows get an order-preserving unsigned 64-bit *code* of the
      key (integer-like and FLOAT64 values: their bits mapped to unsigned
      order; BOOLEAN: 0/1; STRING: the next 3 UTF-16 units in code point
      order plus a \"more units follow\" bit) and are ordered by an LSD radix
      sort of the codes (8 bits per pass, only digits that vary);
    * every run of equal codes is sorted recursively by the next key (or,
      for a string that continues, by the next 3 units of the same key).
  Runs of at most `small-run` rows, keys without a code (wide DECIMAL) and
  very long common string prefixes are sorted by a typed comparator
  (insertion/merge sort). At the top level the runs are processed in
  parallel. Ties are broken by input position, i.e. the sort is stable: rows
  with equal keys keep their input order, as with the row engine's sort."
  (:require [polyquery.exec.context :as ctx]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.util Arrays Comparator List)))

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
  "IndexComparator of one sort key over its extracted [values nulls],
  without the final tie-break."
  [[vals ^booleans nulls] {:keys [type desc? nulls-first?]}]
  (let [sign (if desc? -1 1)
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

(defn- chain-comparator
  "Comparator of row indices by the key comparators `cs` (in order), ties
  by index (stability)."
  ^polyquery.exec.sort.IndexComparator [cs]
  (let [^objects cs (into-array IndexComparator cs)
        k (alength cs)]
    (reify IndexComparator
      (compareIdx [_ a b]
        (loop [i 0]
          (if (< i k)
            (let [r (.compareIdx ^IndexComparator (aget cs i) a b)]
              (if (zero? r) (recur (inc i)) r))
            (Long/compare a b)))))))

;; ---------------------------------------------------------------------------
;; Comparison sorts of index ranges

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

(defn- merge-sort-range!
  "Sorts a[lo, hi) in place (tmp: scratch, only [lo, hi) is used)."
  [^ints a ^ints tmp lo hi ^IndexComparator c]
  (let [lo (long lo) hi (long hi)
        r (merge-sort! a tmp lo hi c)]
    (when-not (identical? r a) (System/arraycopy r lo a lo (- hi lo)))))

;; ---------------------------------------------------------------------------
;; Radix sort of 64-bit codes

(defn- radix-range!
  "Stably sorts p[lo, lo + m) by the unsigned codes ks (m = length of ks,
  ks[i] belongs to p[lo + i]): LSD radix sort, 8 bits per pass, skipping
  digits that are equal in all codes. Returns the sorted codes."
  ^longs [^longs ks ^ints p ^long lo]
  (let [m (alength ks)
        varying (loop [i 0 o 0 a -1]
                  (if (< i m)
                    (let [k (aget ks i)] (recur (inc i) (bit-or o k) (bit-and a k)))
                    (bit-xor o a)))]
    (if (zero? varying)
      ks
      (let [ks2 (long-array m)
            idx (Arrays/copyOfRange p lo (+ lo m))
            idx2 (int-array m)
            counts (int-array 256)]
        (loop [shift 0 ^longs ks ks ^ints idx idx ^longs ks2 ks2 ^ints idx2 idx2]
          (cond
            (>= shift 64)
            (do (System/arraycopy idx 0 p lo m) ks)

            (zero? (bit-and (unsigned-bit-shift-right varying shift) 0xFF))
            (recur (+ shift 8) ks idx ks2 idx2)

            :else
            (do
              (Arrays/fill counts 0)
              (dotimes [i m]
                (let [d (bit-and (unsigned-bit-shift-right (aget ks i) shift) 0xFF)]
                  (aset counts d (inc (aget counts d)))))
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

(defn long-order
  "Stable ascending permutation of signed long keys (radix sort)."
  ^ints [^longs ks qctx]
  (ctx/check! qctx)
  (let [n (alength ks)
        us (long-array n)
        p (int-array n)]
    (dotimes [i n]
      (aset us i (bit-xor (aget ks i) Long/MIN_VALUE))
      (aset p i (int i)))
    (radix-range! us p 0)
    p))

;; ---------------------------------------------------------------------------
;; Key codes: order-preserving unsigned 64-bit encodings

(def ^:private ^:const small-run
  "Runs up to this length are insertion-sorted with the comparator."
  32)

(def ^:private ^:const chunk-units
  "UTF-16 code units per string code."
  3)

(def ^:private ^:const max-string-offset
  "Common string prefixes longer than this are resolved by the comparator."
  60)

(defn- code-kind [type]
  (cond (long-kind? type) :long
        (#{:float64 :boolean :string} (t/kind type)) (t/kind type)
        :else nil))

(defn- unit-code
  "Code of the UTF-16 unit at i (0 past the end): 1 + the unit remapped so
  that unit order is code point order (surrogates after U+E000..U+FFFF, as
  polyquery.util.text/compare-code-points)."
  ^long [^String s ^long i]
  (if (< i (.length s))
    (let [c (long (int (.charAt s i)))]
      (inc (cond (>= c 0xE000) (- c 0x800)
                 (>= c 0xD800) (+ c 0x2000)
                 :else c)))
    0))

(defn- string-code
  "Code of units [off, off + 3) of s: three 17-bit unit codes and a low bit
  set when more units follow. Equal codes without that bit ⇔ equal strings
  (given equal units before off)."
  ^long [^String s ^long off]
  (bit-or (bit-shift-left (unit-code s off) 35)
          (bit-shift-left (unit-code s (+ off 1)) 18)
          (bit-shift-left (unit-code s (+ off 2)) 1)
          (if (> (.length s) (+ off chunk-units)) 1 0)))

(defn- double-code ^long [^double x]
  (let [b (Double/doubleToRawLongBits (if (== x 0.0) 0.0 x))]
    (if (neg? b) (bit-not b) (bit-xor b Long/MIN_VALUE))))

(defn- key-codes
  "Codes of the (non-NULL) values of key `k` for the rows p[lo, hi)."
  ^longs [{:keys [kind vals desc?]} ^ints p lo hi off]
  (let [lo (long lo) hi (long hi) off (long off)
        m (- hi lo)
        ks (long-array m)]
    (case kind
      :long (let [^longs vs vals]
              (dotimes [i m] (aset ks i (bit-xor (aget vs (aget p (+ lo i))) Long/MIN_VALUE))))
      :float64 (let [^doubles vs vals]
                 (dotimes [i m] (aset ks i (double-code (aget vs (aget p (+ lo i)))))))
      :boolean (let [^objects vs vals]
                 (dotimes [i m] (aset ks i (if (.booleanValue ^Boolean (aget vs (aget p (+ lo i)))) 1 0))))
      :string (let [^objects vs vals]
                (dotimes [i m] (aset ks i (string-code (aget vs (aget p (+ lo i))) off)))))
    (when desc?
      (dotimes [i m] (aset ks i (bit-not (aget ks i)))))
    ks))

(defn- split-nulls!
  "Stably moves the rows of p[lo, hi) whose key is NULL to the front
  (nulls-first?) or back; returns the bounds [nlo nhi] of the NULL rows."
  [{:keys [^booleans nulls nulls-first?]} ^ints p lo hi]
  (let [lo (long lo) hi (long hi)
        nn (loop [i lo c 0] (if (< i hi) (recur (inc i) (if (aget nulls (aget p i)) (inc c) c)) c))]
    (if (or (zero? nn) (== nn (- hi lo)))
      [lo (if (zero? nn) lo hi)]
      (let [src (Arrays/copyOfRange p lo hi)
            nlo (if nulls-first? lo (- hi nn))
            vlo (if nulls-first? (+ lo nn) lo)]
        (loop [i 0 a nlo b vlo]
          (when (< i (alength src))
            (let [r (aget src i)]
              (if (aget nulls r)
                (do (aset p a r) (recur (inc i) (inc a) b))
                (do (aset p b r) (recur (inc i) a (inc b)))))))
        [nlo (+ nlo nn)]))))

(deftype Sorter [keys ^objects cmps ^ints tmp qctx])

(defn- runs
  "[start end code] of the runs of equal codes (length > 1) of the sorted
  codes ks, bounds offset by lo."
  [^longs ks ^long lo]
  (let [m (alength ks)]
    (loop [i 0 acc (transient [])]
      (if (< i m)
        (let [k (aget ks i)
              j (long (loop [j (inc i)] (if (and (< j m) (== k (aget ks j))) (recur (inc j)) j)))]
          (recur j (if (> (- j i) 1) (conj! acc [(+ lo i) (+ lo j) k]) acc)))
        (persistent! acc)))))

(defn- sort-range!
  "Sorts p[lo, hi), whose rows are equal on keys before `k` (and on the
  first `off` units of key k, a string), by keys k, k+1, … and position.
  `run-all`, when given, processes the runs found here in parallel chunks."
  [^Sorter s ^ints p lo hi k off run-all parts]
  (let [lo (long lo) hi (long hi) k (long k) off (long off) parts (long parts)
        keys (.-keys s)
        n (- hi lo)]
    (when (and (> n 1) (< k (count keys)))
      (let [{:keys [kind desc?] :as key} (nth keys k)
            ^IndexComparator cmp (aget ^objects (.-cmps s) k)]
        (cond
          (<= n small-run) (insertion-sort! p lo hi cmp)

          (or (nil? kind) (> off max-string-offset)) (merge-sort-range! p (.-tmp s) lo hi cmp)

          :else
          (let [[nlo nhi] (if (zero? off) (split-nulls! key p lo hi) [lo lo])
                nlo (long nlo) nhi (long nhi)
                [vlo vhi] (if (== nlo lo) [nhi hi] [lo nlo])
                vlo (long vlo) vhi (long vhi)
                _ (ctx/check! (.-qctx s))
                ks (if (> (- vhi vlo) 1) (radix-range! (key-codes key p vlo vhi off) p vlo) (long-array 0))
                rs (runs ks vlo)
                process (fn [rs]
                          (doseq [[a b code] rs]
                            ;; strings continuing past this chunk: next chunk
                            (if (and (= :string kind) (odd? (if desc? (bit-not (long code)) (long code))))
                              (sort-range! s p a b k (+ off chunk-units) nil 1)
                              (sort-range! s p a b (inc k) 0 nil 1))))]
            (sort-range! s p nlo nhi (inc k) 0 nil 1)
            (if (and run-all (> parts 1) (> (count rs) 1))
              (let [per (max 1 (quot (+ (count rs) parts -1) parts))]
                (run-all (for [chunk (partition-all per rs)]
                           #(do (ctx/check! (.-qctx s)) (process chunk) nil))))
              (process rs))))))))

;; ---------------------------------------------------------------------------

(defn sort-rows
  "The rows (a java.util.List of Object arrays) sorted by `keys` (ORDER BY
  semantics, stable), as a List. `run-all` runs thunks (in parallel for
  `parts` > 1)."
  ^List [^List rows keys qctx run-all parts]
  (let [^objects arr (.toArray rows)
        n (alength arr)
        cols (mapv #(extract arr n (:index %) (:type %)) keys)
        kcs (mapv key-comparator cols keys)
        sorter (Sorter. (mapv (fn [k [vals nulls]]
                                (assoc k :kind (code-kind (:type k)) :vals vals :nulls nulls))
                              keys cols)
                        (object-array (map #(chain-comparator (drop % kcs)) (range (count keys))))
                        (int-array n)
                        qctx)
        p (int-array n)
        out (object-array n)]
    (dotimes [i n] (aset p i i))
    (sort-range! sorter p 0 n 0 0 run-all (long parts))
    (dotimes [i n] (aset out i (aget arr (aget p i))))
    (Arrays/asList out)))
