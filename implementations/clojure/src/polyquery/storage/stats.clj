(ns polyquery.storage.stats
  "Per-table statistics (spec/storage/indexes-and-planning.md §3,
  protocol.md §5.8): row count and, per column, null count, min, max and an
  approximate distinct count.

  Distinct values are counted exactly up to `exact-limit` distinct values;
  beyond that a HyperLogLog sketch (2^14 registers, ~1% standard error)
  takes over. Column statistics are computed lazily (on first use by `stats`
  or the planner) and cached in the table value."
  (:require [polyquery.storage.table :as table]
            [polyquery.values :as v])
  (:import (java.util HashSet)
           (polyquery.storage.column ColumnVector)))

(set! *warn-on-reflection* true)

(def ^:private exact-limit 65536)
(def ^:private hll-bits 14)
(def ^:private hll-size (bit-shift-left 1 hll-bits))

(defn- mix64
  "64-bit finalizer (MurmurHash3 fmix64) spreading a hash code."
  ^long [^long h]
  (let [h (bit-xor h (unsigned-bit-shift-right h 33))
        h (unchecked-multiply h (unchecked-long 0xff51afd7ed558ccd))
        h (bit-xor h (unsigned-bit-shift-right h 33))
        h (unchecked-multiply h (unchecked-long 0xc4ceb9fe1a85ec53))]
    (bit-xor h (unsigned-bit-shift-right h 33))))

(defn- value-hash ^long [x]
  (if (instance? Long x)
    (mix64 (long x))
    (mix64 (unchecked-add (unchecked-multiply (long (.hashCode ^Object x)) 31)
                          (long (.hashCode ^Object (class x)))))))

(defn- hll-add! [^bytes registers x]
  (let [h (value-hash x)
        idx (int (unsigned-bit-shift-right h (- 64 (long hll-bits))))
        rest-bits (bit-or (bit-shift-left h hll-bits) (bit-shift-left 1 (dec (long hll-bits))))
        rank (inc (Long/numberOfLeadingZeros rest-bits))]
    (when (> rank (aget registers idx))
      (aset registers idx (byte rank)))))

(defn- hll-estimate ^long [^bytes registers]
  (let [m (double hll-size)
        [sum zeros] (areduce registers i [s z] [0.0 0]
                             (let [r (aget registers i)]
                               [(+ (double s) (Math/pow 2.0 (- r))) (if (zero? r) (inc (long z)) z)]))
        alpha (/ 0.7213 (+ 1.0 (/ 1.079 m)))
        raw (/ (* alpha m m) (double sum))]
    (Math/round (double (if (and (<= raw (* 2.5 m)) (pos? (long zeros)))
                          (* m (Math/log (/ m (double zeros))))
                          raw)))))

(defn- distinct-counter
  "Returns [add! count] functions over non-null values."
  []
  (let [exact (HashSet.)
        registers (volatile! nil)]
    [(fn [x]
       (let [k (v/normalize-key x)]
         (if-let [^bytes regs @registers]
           (hll-add! regs k)
           (do (.add exact k)
               (when (> (.size exact) (long exact-limit))
                 (let [regs (byte-array hll-size)]
                   (doseq [y exact] (hll-add! regs y))
                   (.clear exact)
                   (vreset! registers regs)))))))
     (fn [] (if-let [regs @registers] (hll-estimate regs) (.size exact)))]))

(defn compute-column-stats
  "{:null-count :distinct-count :min :max} of column i (min/max nil when
  there is no non-null value)."
  [tbl ^long i]
  (let [t (:type (nth (:columns tbl) i))
        cmp (v/value-comparator t)
        [add! distinct-count] (distinct-counter)]
    (loop [segs (:segments tbl) nulls 0 mn nil mx nil]
      (if-let [seg (first segs)]
        (let [^ColumnVector vec (table/segment-vector seg i)
              n (long (:row-count seg))
              [nulls mn mx] (loop [r 0 nulls nulls mn mn mx mx]
                              (if (< r n)
                                (let [x (.valueAt vec r)]
                                  (if (nil? x)
                                    (recur (inc r) (inc (long nulls)) mn mx)
                                    (do (add! x)
                                        (recur (inc r) nulls
                                               (if (or (nil? mn) (neg? (.compare cmp x mn))) x mn)
                                               (if (or (nil? mx) (pos? (.compare cmp x mx))) x mx)))))
                                [nulls mn mx]))]
          (recur (next segs) (long nulls) mn mx))
        {:null-count nulls :distinct-count (distinct-count) :min mn :max mx}))))

(defn with-stats
  "Attaches lazily computed column statistics to a table."
  [tbl]
  (assoc tbl :stats (mapv (fn [i] (delay (compute-column-stats tbl i)))
                          (range (count (:columns tbl))))))

(defn column-stats
  "Statistics of column i of a table."
  [tbl ^long i]
  (if-let [s (nth (:stats tbl) i nil)]
    @s
    (compute-column-stats tbl i)))
