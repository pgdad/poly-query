(ns polyquery.exec.grouping
  "Data structures of vectorized hash aggregation: group tables mapping the
  key values of a batch's rows to dense group ids (in order of first
  appearance), and aggregate states stored column-wise as primitive arrays
  indexed by group id.

  Group tables:
    GlobalTable    no GROUP BY keys: one group
    LongKeyTable   one INT64/DECIMAL/DATE/TIMESTAMP key: open addressing
                   over a long[] (linear probing, power-of-two capacity,
                   keys and group ids in parallel primitive arrays — no
                   boxing, no per-entry objects)
    MultiKeyTable  2..30 keys: every key value becomes a long code (the
                   value of integer-like keys, the bits of FLOAT64, 0/1,
                   or an interned id for other values — dictionary codes
                   are mapped per dictionary); open addressing over the
                   code tuples, stored in a long[] (no per-row objects)
    ObjKeyTable    any other keys: HashMap over normalized key values; a
                   single dictionary-encoded STRING key is mapped through a
                   per-dictionary code → group id array
  Aggregate states: COUNT, and SUM/AVG/MIN/MAX over integer-like and
  FLOAT64 values use typed arrays; DISTINCT over integer-like values one
  primitive hash set (LongSet) per group; everything else (other DISTINCT,
  MIN/MAX of strings, …) one Accumulator (polyquery.exec.aggregate) per
  group. All
  states can merge the states of another table (parallel aggregation) and
  produce exactly the results of the row engine's accumulators.

  Native kernels (`native: true`, polyquery.native.ffi): a LongKeyTable
  created with the library hashes the keys of a whole batch with
  pqk_hash_i64 (fmix64, also used for its single-key lookups); exact
  SUM/AVG states feed integer batches through pqk_group_sum_i64 (or
  pqk_sum_i64 without GROUP BY), MIN/MAX without GROUP BY use
  pqk_minmax_i64 / pqk_minmax_f64 (NativeUpdate). Kernel overflow flags
  are honoured: an overflowing batch is undone and recomputed exactly by
  the Java code, so results are identical with and without the library."
  (:require [polyquery.errors :as err]
            [polyquery.exec.aggregate :as agg]
            [polyquery.exec.batch :as b :refer [each-sel]]
            [polyquery.native.bits :as bits]
            [polyquery.native.ffi :as ffi]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.math BigInteger)
           (java.util ArrayList Arrays Comparator HashMap IdentityHashMap)
           (polyquery.exec.aggregate Accumulator)
           (polyquery.exec.batch DictVec DoubleVec LongVec Vec)
           (polyquery.native.ffi Library)))

(set! *warn-on-reflection* true)

(definterface GroupTable
  (^long size [])
  (assign [^"[Ljava.lang.Object;" keyVecs ^ints sel ^long n ^ints gids]
          "Stores the group id of every selected row in gids (by position),
          adding new groups.")
  (keyAt [^long gid] "Object[] of the key values of a group.")
  (^long findOrAdd [^"[Ljava.lang.Object;" keyVals] "Group id of the given key values."))

(defn- grow-longs ^longs [^longs a ^long n]
  (if (>= (alength a) n) a (Arrays/copyOf a (int (max n (* 2 (alength a)))))))

(defn- grow-doubles ^doubles [^doubles a ^long n]
  (if (>= (alength a) n) a (Arrays/copyOf a (int (max n (* 2 (alength a)))))))

(defn- grow-booleans ^booleans [^booleans a ^long n]
  (if (>= (alength a) n) a (Arrays/copyOf a (int (max n (* 2 (alength a)))))))

(defn- grow-objects ^objects [^objects a ^long n]
  (if (>= (alength a) n) a (Arrays/copyOf a (int (max n (* 2 (alength a)))))))

;; ---------------------------------------------------------------------------
;; Group tables

(deftype GlobalTable []
  GroupTable
  (size [_] 1)
  (assign [_ _ sel n gids] (each-sel [i sel n] (aset gids i 0)))
  (keyAt [_ _] (object-array 0))
  (findOrAdd [_ _] 0))

(defn- mix ^long [^long k]
  (let [h (unchecked-multiply k -7046029254386353131)]
    (bit-xor h (unsigned-bit-shift-right h 29))))

(defn fmix64
  "MurmurHash3's 64-bit finalizer: pqk_hash_i64 with seed 0."
  ^long [^long k]
  (let [k (bit-xor k (unsigned-bit-shift-right k 33))
        k (unchecked-multiply k -49064778989728563)
        k (bit-xor k (unsigned-bit-shift-right k 33))
        k (unchecked-multiply k -4265267296055464877)]
    (bit-xor k (unsigned-bit-shift-right k 33))))

(definterface LongLookup
  (^long lookup [^long k] "Group id of non-NULL key k (added if new).")
  (^long lookupHashed [^long k ^long h] "lookup of key k with hash h.")
  (^long find [^long k] "Group id of key k, -1 if absent.")
  (^long findHashed [^long k ^long h] "find of key k with hash h.")
  (^long hashOf [^long k])
  (^long keyLong [^long gid] "The key of a group (not the NULL group).")
  (^long nullGid [] "Group id of the NULL key, -1 if none.")
  (rehash []))

(deftype LongKeyTable [^:unsynchronized-mutable ^longs slot-keys
                       ^:unsynchronized-mutable ^ints slot-gids ; gid + 1, 0 = empty
                       ^:unsynchronized-mutable ^long mask
                       ^:unsynchronized-mutable ^longs gid-keys
                       ^:unsynchronized-mutable ^long cnt
                       ^:unsynchronized-mutable ^long null-gid
                       ^Library lib       ; non-nil: fmix64 hashing, batches hashed natively
                       ^longs hashes]     ; per-batch hash buffer (lib only)
  GroupTable
  (size [_] cnt)
  (keyAt [_ gid] (object-array [(when-not (= gid null-gid) (aget gid-keys gid))]))
  (findOrAdd [this kv]
    (let [k (aget kv 0)]
      (if (nil? k)
        (do (when (neg? null-gid)
              (set! null-gid cnt)
              (set! gid-keys (grow-longs gid-keys (inc cnt)))
              (set! cnt (inc cnt)))
            null-gid)
        (.lookup this (long k)))))
  (assign [this kvs sel n gids]
    (let [^LongVec x (aget kvs 0)
          vals ^longs (.-v x)
          nulls ^booleans (.-nulls x)]
      (if lib
        (do (ffi/hash-i64! lib vals (bits/span sel n) 0 hashes)
            (if nulls
              (each-sel [i sel n]
                (aset gids i (int (if (aget nulls i)
                                    (.findOrAdd this (object-array 1))
                                    (.lookupHashed this (aget vals i) (aget hashes i))))))
              (each-sel [i sel n]
                (aset gids i (int (.lookupHashed this (aget vals i) (aget hashes i)))))))
        (if nulls
          (each-sel [i sel n]
            (aset gids i (int (if (aget nulls i)
                                (.findOrAdd this (object-array 1))
                                (.lookup this (aget vals i))))))
          (each-sel [i sel n]
            (aset gids i (int (.lookup this (aget vals i)))))))))

  LongLookup
  (keyLong [_ gid] (aget gid-keys gid))
  (nullGid [_] null-gid)
  (hashOf [_ k] (if lib (fmix64 k) (mix k)))
  (find [this k] (.findHashed this k (.hashOf this k)))
  (findHashed [_ k h]
    (loop [s (bit-and h mask)]
      (let [g (aget slot-gids s)]
        (cond
          (zero? g) -1
          (== k (aget slot-keys s)) (dec g)
          :else (recur (bit-and (inc s) mask))))))
  (lookup [this k] (.lookupHashed this k (.hashOf this k)))
  (lookupHashed [this k h]
    (loop [s (bit-and h mask)]
      (let [g (aget slot-gids s)]
        (cond
          (zero? g)
          (let [gid cnt]
            (aset slot-keys s k)
            (aset slot-gids s (int (inc gid)))
            (set! gid-keys (grow-longs gid-keys (inc gid)))
            (aset gid-keys gid k)
            (set! cnt (inc gid))
            (when (> (* 2 cnt) mask) (.rehash this))
            gid)
          (== k (aget slot-keys s)) (dec g)
          :else (recur (bit-and (inc s) mask))))))
  (rehash [this]
    (let [cap (* 2 (inc mask))
          nkeys (long-array cap)
          ngids (int-array cap)
          nmask (dec cap)]
      (dotimes [s (alength slot-gids)]
        (let [g (aget slot-gids s)]
          (when-not (zero? g)
            (let [k (aget slot-keys s)]
              (loop [t (bit-and (.hashOf this k) nmask)]
                (if (zero? (aget ngids t))
                  (do (aset nkeys t k) (aset ngids t g))
                  (recur (bit-and (inc t) nmask))))))))
      (set! slot-keys nkeys)
      (set! slot-gids ngids)
      (set! mask nmask)
      nil)))

(defn long-key-table
  "An empty LongKeyTable (hashing with the native kernels of lib, if
  non-nil)."
  (^polyquery.exec.grouping.LongKeyTable [] (long-key-table nil))
  (^polyquery.exec.grouping.LongKeyTable [lib]
   (LongKeyTable. (long-array 1024) (int-array 1024) 1023 (long-array 256) 0 -1
                  lib (when lib (long-array b/capacity)))))

(definterface ObjLookup
  (^long lookupKey [k] "Group id of a hashable key (added if new)."))

(deftype ObjKeyTable [^HashMap ids ^ArrayList key-vals ^long nkeys ^IdentityHashMap dicts]
  GroupTable
  (size [_] (.size key-vals))
  (keyAt [_ gid] (.get key-vals gid))
  (findOrAdd [this kv]
    (.lookupKey this (if (= 1 nkeys)
                       (v/normalize-key (aget kv 0))
                       (Arrays/asList (object-array (map v/normalize-key kv))))))
  (assign [this kvs sel n gids]
    (let [x (aget kvs 0)]
      (cond
        (and (= 1 nkeys) (instance? DictVec x))
        ;; one dictionary-encoded key: code → group id through a per-dictionary array
        (let [^DictVec d x
              dict ^objects (.-dict d)
              codes ^ints (.-codes d)
              nulls ^booleans (.-nulls d)
              ^ints m (or (.get dicts dict)
                          (let [m (doto (int-array (alength dict)) (Arrays/fill -1))]
                            (.put dicts dict m)
                            m))]
          (each-sel [i sel n]
            (aset gids i (int (if (b/nulls-at? nulls i)
                                (.lookupKey this nil)
                                (let [c (aget codes i)
                                      g (aget m c)]
                                  (if (neg? g)
                                    (let [g (.lookupKey this (aget dict c))]
                                      (aset m c (int g))
                                      g)
                                    g)))))))

        (= 1 nkeys)
        (let [^Vec x x]
          (each-sel [i sel n]
            (aset gids i (int (.lookupKey this (v/normalize-key (.getObj x i)))))))

        :else
        (each-sel [i sel n]
          (let [kv (object-array nkeys)]
            (dotimes [j nkeys] (aset kv j (v/normalize-key (.getObj ^Vec (aget kvs j) i))))
            (aset gids i (int (.lookupKey this (Arrays/asList kv)))))))))
  ObjLookup
  (lookupKey [_ k]
    (let [g (.get ids k)]
      (if (some? g)
        (long g)
        (let [gid (.size key-vals)]
          (.put ids k (Integer/valueOf (int gid)))
          (.add key-vals (if (= 1 nkeys)
                           (object-array [k])
                           (.toArray ^java.util.List k)))
          gid)))))

(definterface MultiKeyOps
  (^long codeOf [^long j x] "Key code of non-NULL value x of key j.")
  (^long probe [^longs codes ^long nulls] "Group id of a code tuple (added if new).")
  (^long hashCodes [^longs codes ^long off ^long nulls])
  (growSlots []))

(def ^:private ^:const kind-long 0)
(def ^:private ^:const kind-double 1)
(def ^:private ^:const kind-bool 2)
(def ^:private ^:const kind-obj 3)

(deftype MultiKeyTable [^ints kinds
                        ^long nkeys
                        ^HashMap interned          ; value → id (:obj keys)
                        ^ArrayList intern-vals     ; id → value
                        ^IdentityHashMap dicts     ; dictionary → int[] code → id
                        ^:unsynchronized-mutable ^ints slots ; gid + 1, 0 = empty
                        ^:unsynchronized-mutable ^long mask
                        ^:unsynchronized-mutable ^longs gkeys ; gid * nkeys + j
                        ^:unsynchronized-mutable ^longs gnulls ; NULL bitmask per gid
                        ^:unsynchronized-mutable ^long cnt
                        ^objects row-codes         ; long[capacity] per key
                        ^longs row-nulls
                        ^longs tuple]
  GroupTable
  (size [_] cnt)
  (keyAt [_ gid]
    (let [out (object-array nkeys)
          nm (aget gnulls gid)]
      (dotimes [j nkeys]
        (when (zero? (bit-and nm (bit-shift-left 1 j)))
          (let [c (aget gkeys (+ (* gid nkeys) j))]
            (aset out j (case (aget kinds j)
                          0 c
                          1 (Double/longBitsToDouble c)
                          2 (== c 1)
                          (.get intern-vals (int c)))))))
      out))
  (findOrAdd [this kv]
    (let [codes (long-array nkeys)]
      (loop [j 0 nm 0]
        (if (< j nkeys)
          (let [x (aget ^objects kv j)]
            (if (nil? x)
              (recur (inc j) (bit-or nm (bit-shift-left 1 j)))
              (do (aset codes j (.codeOf this j x)) (recur (inc j) nm))))
          (.probe this codes nm)))))
  (assign [this kvs sel n gids]
    (each-sel [i sel n] (aset row-nulls i 0))
    (dotimes [j nkeys]
      (let [^longs out (aget row-codes j)
            x (aget ^objects kvs j)
            bit (bit-shift-left 1 j)
            null! (fn [^long i] (aset row-nulls i (bit-or (aget row-nulls i) bit)))]
        (cond
          (and (instance? LongVec x) (== kind-long (aget kinds j)))
          (let [^LongVec x x ^longs v (.-v x) ^booleans nulls (.-nulls x)]
            (each-sel [i sel n]
              (if (b/nulls-at? nulls i) (null! i) (aset out i (aget v i)))))

          (and (instance? DictVec x) (== kind-obj (aget kinds j)))
          (let [^DictVec d x
                ^objects dict (.-dict d)
                ^ints codes (.-codes d)
                ^booleans nulls (.-nulls d)
                ^ints m (or (.get dicts dict)
                            (let [m (doto (int-array (alength dict)) (Arrays/fill -1))]
                              (.put dicts dict m)
                              m))]
            (each-sel [i sel n]
              (if (b/nulls-at? nulls i)
                (null! i)
                (let [c (aget codes i)
                      id (aget m c)]
                  (aset out i (long (if (neg? id)
                                      (let [id (.codeOf this j (aget dict c))]
                                        (aset m c (int id))
                                        id)
                                      id)))))))

          :else
          (let [^Vec x x]
            (each-sel [i sel n]
              (let [y (.getObj x i)]
                (if (nil? y) (null! i) (aset out i (.codeOf this j y)))))))))
    (each-sel [i sel n]
      (let [nm (aget row-nulls i)]
        ;; NULL keys have code 0 (their slot in row-codes is stale)
        (dotimes [j nkeys]
          (aset tuple j (if (zero? (bit-and nm (bit-shift-left 1 j)))
                          (aget ^longs (aget row-codes j) i)
                          0)))
        (aset gids i (int (.probe this tuple nm))))))
  MultiKeyOps
  (codeOf [_ j x]
    (case (aget kinds j)
      0 (long x)
      1 (Double/doubleToLongBits (double (v/normalize-key x)))
      2 (if (boolean x) 1 0)
      (let [k (v/normalize-key x)
            id (.get interned k)]
        (if (some? id)
          (long id)
          (let [id (.size intern-vals)]
            (.put interned k (Integer/valueOf (int id)))
            (.add intern-vals k)
            id)))))
  (hashCodes [_ codes off nulls]
    (loop [j 0 h (mix (+ nulls 0x632BE59BD9B4E019))]
      (if (< j nkeys)
        (recur (inc j) (mix (bit-xor h (aget codes (+ off j)))))
        h)))
  (probe [this codes nulls]
    (let [h (.hashCodes this codes 0 nulls)]
      (loop [s (bit-and h mask)]
        (let [g1 (aget slots s)]
          (if (zero? g1)
            (let [gid cnt]
              (when (>= (* (inc gid) nkeys) (alength gkeys))
                (set! gkeys (grow-longs gkeys (* 2 (inc gid) nkeys)))
                (set! gnulls (grow-longs gnulls (* 2 (inc gid)))))
              (System/arraycopy codes 0 gkeys (* gid nkeys) nkeys)
              (aset gnulls gid nulls)
              (aset slots s (int (inc gid)))
              (set! cnt (inc gid))
              (when (> (* 2 cnt) mask) (.growSlots this))
              gid)
            (let [g (dec g1)
                  base (* g nkeys)]
              (if (and (== nulls (aget gnulls g))
                       (loop [j 0]
                         (cond (>= j nkeys) true
                               (== (aget codes j) (aget gkeys (+ base j))) (recur (inc j))
                               :else false)))
                g
                (recur (bit-and (inc s) mask)))))))))
  (growSlots [this]
    (let [cap (* 2 (alength slots))
          ns (int-array cap)
          nmask (dec cap)]
      (dotimes [g cnt]
        (loop [t (bit-and (.hashCodes this gkeys (* g nkeys) (aget gnulls g)) nmask)]
          (if (zero? (aget ns t))
            (aset ns t (int (inc g)))
            (recur (bit-and (inc t) nmask)))))
      (set! slots ns)
      (set! mask nmask)
      nil)))

(defn- multi-key-table
  "A MultiKeyTable for 2..30 keys of the given types."
  ^polyquery.exec.grouping.MultiKeyTable [key-types]
  (let [nkeys (count key-types)]
    (MultiKeyTable. (int-array (map #(case (b/vec-kind %) :long 0 :double 1 :bool 2 :obj 3) key-types))
                    nkeys (HashMap.) (ArrayList.) (IdentityHashMap.)
                    (int-array 1024) 1023 (long-array (* 64 nkeys)) (long-array 64) 0
                    (object-array (repeatedly nkeys #(long-array b/capacity)))
                    (long-array b/capacity) (long-array nkeys))))

(defn group-table
  "A group table for keys of the given types (lib: the native kernel
  library or nil)."
  (^polyquery.exec.grouping.GroupTable [key-types] (group-table key-types nil))
  (^polyquery.exec.grouping.GroupTable [key-types lib]
   (cond
     (empty? key-types) (GlobalTable.)
     (and (= 1 (count key-types)) (= :long (b/vec-kind (first key-types)))) (long-key-table lib)
     (<= 2 (count key-types) 30) (multi-key-table key-types)
     :else (ObjKeyTable. (HashMap.) (ArrayList.) (count key-types) (IdentityHashMap.)))))

;; ---------------------------------------------------------------------------
;; Aggregate states

(definterface AggState
  (grow [^long size] "Makes room for group ids < size.")
  (update [^ints gids arg ^ints sel ^long n] "Feeds the selected values of vector arg.")
  (mergeFrom [other ^long from ^long to] "Adds group `from` of state other to group `to`.")
  (result [^long gid]))

(definterface NativeUpdate
  (^boolean nativeUpdate [^ints gids arg ^ints sel ^long n ^boolean global]
   "Feeds the selected values of vector arg through the native kernels
   (global: no GROUP BY, every gid is 0). Returns false, with the state
   unchanged, when the batch must go through `update` instead."))

(definterface Counts
  (^long countAt [^long g] "The count of group g."))

(deftype CountState [star? ^:unsynchronized-mutable ^longs c]
  Counts
  (countAt [_ g] (aget c g))
  AggState
  (grow [_ size] (set! c (grow-longs c size)))
  (update [_ gids arg sel n]
    (if star?
      (each-sel [i sel n] (let [g (aget gids i)] (aset c g (inc (aget c g)))))
      (let [^Vec arg arg]
        (each-sel [i sel n]
          (when-not (.isNullAt arg i)
            (let [g (aget gids i)] (aset c g (inc (aget c g)))))))))
  (mergeFrom [_ other from to]
    (aset c to (+ (aget c to) (.countAt ^Counts other from))))
  (result [_ gid] (aget c gid)))

(definterface ExactSums
  (counts [])
  (exact [^long g] "The exact sum of group g (Long or BigInteger).")
  (^boolean isBig [^long g] "True when the sum of group g is held as a BigInteger.")
  (^long sumAt [^long g] "The sum of group g when it is not big.")
  (addBig [^long g ^java.math.BigInteger y]))

(deftype LongSumState [finish
                       ^:unsynchronized-mutable ^longs sums
                       ^:unsynchronized-mutable ^longs cnts
                       ^:unsynchronized-mutable ^objects bigs
                       ^Library lib
                       ^longs vbits]
  AggState
  (grow [_ size]
    (set! sums (grow-longs sums size))
    (set! cnts (grow-longs cnts size))
    (when bigs (set! bigs (grow-objects bigs size))))
  (update [this gids arg sel n]
    (let [^LongVec x arg
          vals ^longs (.-v x)
          nulls ^booleans (.-nulls x)]
      (each-sel [i sel n]
        (when-not (b/nulls-at? nulls i)
          (let [g (aget gids i)
                y (aget vals i)
                s (aget sums g)
                r (unchecked-add s y)]
            (aset cnts g (inc (aget cnts g)))
            (if (or (neg? (bit-and (bit-xor s r) (bit-xor y r)))
                    (and bigs (some? (aget bigs g))))
              (.addBig this g (BigInteger/valueOf y))
              (aset sums g r)))))))
  (mergeFrom [this other from to]
    (let [^LongSumState o other
          m (aget ^longs (.counts o) from)]
      (when (pos? m)
        (if (.isBig o from)
          (.addBig this to (.exact o from))
          (let [y (.sumAt o from) s (aget sums to) r (unchecked-add s y)]
            (if (or (neg? (bit-and (bit-xor s r) (bit-xor y r)))
                    (and bigs (some? (aget bigs to))))
              (.addBig this to (BigInteger/valueOf y))
              (aset sums to r))))
        (aset cnts to (+ (aget cnts to) m)))))
  (result [this gid]
    (let [m (aget cnts gid)]
      (finish (when (pos? m) (.exact this gid)) m)))

  NativeUpdate
  (nativeUpdate [this gids arg sel n global]
    (if (or (nil? lib) (some? bigs) (not (instance? LongVec arg)))
      false
      (let [^LongVec x arg
            vals ^longs (.-v x)
            span (bits/span sel n)
            valid (bits/valid-sel-bits! (.-nulls x) sel n vbits)]
        (if global
          ;; one exact (128-bit) batch sum, added with the overflow check
          (let [out (long-array 1)]
            (if (== ffi/OK (ffi/sum-i64 lib vals valid span out))
              (let [m (if valid (ffi/popcount lib valid span) span)]
                (when (pos? m)
                  (let [y (aget out 0) s (aget sums 0) r (unchecked-add s y)]
                    (if (neg? (bit-and (bit-xor s r) (bit-xor y r)))
                      (.addBig this 0 (BigInteger/valueOf y))
                      (aset sums 0 r))
                    (aset cnts 0 (+ (aget cnts 0) m))))
                true)
              false))
          (let [st (ffi/group-sum-i64 lib gids vals valid span sums cnts
                                      (min (alength sums) (alength cnts)))]
            (cond
              (== st ffi/OK) true
              (== st ffi/OVERFLOW)
              ;; some addition wrapped: undo the batch (wrapping arithmetic
              ;; is exactly invertible), the Java update recomputes it exactly
              (do (dotimes [i span]
                    (when (or (nil? valid) (bits/bit-set? valid i))
                      (let [g (aget gids i)]
                        (aset sums g (unchecked-subtract (aget sums g) (aget vals i)))
                        (aset cnts g (dec (aget cnts g))))))
                  false)
              :else false))))))

  ExactSums
  (counts [_] cnts)
  (exact [_ g] (or (when bigs (aget bigs g)) (aget sums g)))
  (isBig [_ g] (boolean (and bigs (some? (aget bigs g)))))
  (sumAt [_ g] (aget sums g))
  (addBig [_ g y]
    (when-not bigs (set! bigs (object-array (alength sums))))
    (let [^BigInteger cur (or (aget bigs g) (BigInteger/valueOf (aget sums g)))]
      (aset bigs g (.add cur y)))))

(definterface DoubleSums
  (sumsArr [])
  (countsArr []))

(deftype DoubleSumState [avg?
                         ^:unsynchronized-mutable ^doubles sums
                         ^:unsynchronized-mutable ^longs cnts]
  AggState
  (grow [_ size]
    (set! sums (grow-doubles sums size))
    (set! cnts (grow-longs cnts size)))
  (update [_ gids arg sel n]
    (let [^DoubleVec x arg
          vals ^doubles (.-v x)
          nulls ^booleans (.-nulls x)]
      (each-sel [i sel n]
        (when-not (b/nulls-at? nulls i)
          (let [g (aget gids i)]
            (aset sums g (+ (aget sums g) (aget vals i)))
            (aset cnts g (inc (aget cnts g))))))))
  (mergeFrom [_ other from to]
    (let [^DoubleSumState o other]
      (aset sums to (+ (aget sums to) (aget ^doubles (.sumsArr o) from)))
      (aset cnts to (+ (aget cnts to) (aget ^longs (.countsArr o) from)))))
  (result [_ gid]
    (let [m (aget cnts gid)]
      (when (pos? m)
        (let [s (aget sums gid)
              r (if avg? (/ s m) s)]
          (if (or (Double/isInfinite r) (Double/isNaN r))
            (err/fail! "NUMERIC_OVERFLOW" "floating point overflow in SUM")
            r)))))
  DoubleSums
  (sumsArr [_] sums)
  (countsArr [_] cnts))

(deftype LongExtremeState [^long sign
                           ^:unsynchronized-mutable ^longs best
                           ^:unsynchronized-mutable ^booleans has
                           ^Library lib
                           ^longs vbits]
  AggState
  (grow [_ size]
    (set! best (grow-longs best size))
    (set! has (grow-booleans has size)))
  (update [this gids arg sel n]
    (let [^LongVec x arg
          vals ^longs (.-v x)
          nulls ^booleans (.-nulls x)]
      (each-sel [i sel n]
        (when-not (b/nulls-at? nulls i)
          (let [g (aget gids i) y (aget vals i)]
            (when (or (not (aget has g)) (if (pos? sign) (< y (aget best g)) (> y (aget best g))))
              (aset best g y)
              (aset has g true)))))))
  (mergeFrom [_ other from to]
    (let [y (.result ^AggState other from)]
      (when (some? y)
        (let [y (long y)]
          (when (or (not (aget has to)) (if (pos? sign) (< y (aget best to)) (> y (aget best to))))
            (aset best to y)
            (aset has to true))))))
  (result [_ gid] (when (aget has gid) (aget best gid)))
  NativeUpdate
  (nativeUpdate [_ _ arg sel n global]
    (if (or (nil? lib) (not global) (not (instance? LongVec arg)))
      false
      (let [^LongVec x arg
            out (long-array 2)
            span (bits/span sel n)
            m (ffi/minmax-i64 lib (.-v x) (bits/valid-sel-bits! (.-nulls x) sel n vbits) span out)]
        (when (pos? m)
          (let [y (if (pos? sign) (aget out 0) (aget out 1))]
            (when (or (not (aget has 0)) (if (pos? sign) (< y (aget best 0)) (> y (aget best 0))))
              (aset best 0 y)
              (aset has 0 true))))
        true))))

(deftype DoubleExtremeState [^long sign
                             ^:unsynchronized-mutable ^doubles best
                             ^:unsynchronized-mutable ^booleans has
                             ^Library lib
                             ^longs vbits]
  AggState
  (grow [_ size]
    (set! best (grow-doubles best size))
    (set! has (grow-booleans has size)))
  (update [_ gids arg sel n]
    (let [^DoubleVec x arg
          vals ^doubles (.-v x)
          nulls ^booleans (.-nulls x)]
      (each-sel [i sel n]
        (when-not (b/nulls-at? nulls i)
          (let [g (aget gids i) y (aget vals i)]
            (when (or (not (aget has g))
                      (if (pos? sign) (< y (aget best g)) (> y (aget best g))))
              (aset best g y)
              (aset has g true)))))))
  (mergeFrom [_ other from to]
    (let [y (.result ^AggState other from)]
      (when (some? y)
        (let [y (double y)]
          (when (or (not (aget has to))
                    (if (pos? sign) (< y (aget best to)) (> y (aget best to))))
            (aset best to y)
            (aset has to true))))))
  (result [_ gid] (when (aget has gid) (aget best gid)))
  NativeUpdate
  (nativeUpdate [_ _ arg sel n global]
    (if (or (nil? lib) (not global) (not (instance? DoubleVec arg)))
      false
      (let [^DoubleVec x arg
            out (double-array 2)
            span (bits/span sel n)
            m (ffi/minmax-f64 lib (.-v x) (bits/valid-sel-bits! (.-nulls x) sel n vbits) span out)
            y (if (pos? sign) (aget out 0) (aget out 1))]
        (cond
          (zero? m) true
          ;; 0.0 and -0.0 compare equal: which one is kept depends on the
          ;; evaluation order, so zeros are left to the Java loop
          (== y 0.0) false
          :else (do (when (or (not (aget has 0))
                              (if (pos? sign) (< y (aget best 0)) (> y (aget best 0))))
                      (aset best 0 y)
                      (aset has 0 true))
                    true))))))

;; DISTINCT over integer-like values: one primitive hash set per group.

(definterface LongSetOps
  (^boolean add [^long k] "Adds k; true when it was not present.")
  (^long size [])
  (^longs toArray [] "The elements (in no particular order)."))

(deftype LongSet [^:unsynchronized-mutable ^longs slots ; 0 = empty slot
                  ^:unsynchronized-mutable ^long mask
                  ^:unsynchronized-mutable ^long n
                  ^:unsynchronized-mutable has-zero?]
  LongSetOps
  (add [this k]
    (if (zero? k)
      (if has-zero? false (do (set! has-zero? true) (set! n (inc n)) true))
      (loop [i (bit-and (mix k) mask)]
        (let [x (aget slots i)]
          (cond
            (== x k) false
            (zero? x) (do (aset slots i k)
                          (set! n (inc n))
                          (when (> (* 2 n) mask)
                            (let [old slots
                                  cap (* 2 (alength old))]
                              (set! slots (long-array cap))
                              (set! mask (dec cap))
                              (dotimes [j (alength old)]
                                (let [y (aget old j)]
                                  (when-not (zero? y)
                                    (loop [p (bit-and (mix y) mask)]
                                      (if (zero? (aget slots p))
                                        (aset slots p y)
                                        (recur (bit-and (inc p) mask)))))))))
                          true)
            :else (recur (bit-and (inc i) mask)))))))
  (size [_] n)
  (toArray [_]
    (let [out (long-array n)
          start (if has-zero? 1 0)]
      (loop [j 0 o start]
        (if (< j (alength slots))
          (let [y (aget slots j)]
            (if (zero? y) (recur (inc j) o) (do (aset out o y) (recur (inc j) (inc o)))))
          out)))))

(defn- long-set ^LongSet [] (LongSet. (long-array 8) 7 0 false))

(definterface LongSets
  (^polyquery.exec.grouping.LongSet setOf [^long g] "The set of group g (created on first use)."))

(deftype DistinctLongState [count? make-inner ^:unsynchronized-mutable ^objects sets]
  AggState
  (grow [_ size] (set! sets (grow-objects sets size)))
  (update [this gids arg sel n]
    (if (instance? LongVec arg)
      (let [^LongVec x arg
            ^longs vals (.-v x)
            ^booleans nulls (.-nulls x)]
        (each-sel [i sel n]
          (when-not (b/nulls-at? nulls i)
            (.add (.setOf this (aget gids i)) (aget vals i)))))
      (let [^Vec x arg]
        (each-sel [i sel n]
          (when-some [y (.getObj x i)]
            (.add (.setOf this (aget gids i)) (long y)))))))
  (mergeFrom [this other from to]
    (let [^longs ys (.toArray (.setOf ^LongSets other from))
          s (.setOf this to)]
      (dotimes [j (alength ys)] (.add s (aget ys j)))))
  (result [this gid]
    (let [s (.setOf this gid)]
      (if count?
        (.size s)
        ;; the values in ascending order (as for any order: exact arithmetic)
        (let [^Accumulator inner (make-inner)
              ys (.toArray s)]
          (Arrays/sort ys)
          (dotimes [j (alength ys)] (.add inner (aget ys j)))
          (.result inner)))))
  LongSets
  (setOf [_ g]
    (or (aget sets g)
        (let [s (long-set)] (aset sets g s) s))))

(definterface Accs
  (acc [^long g] "The accumulator of group g (created on first use)."))

(deftype AccState [factory ^:unsynchronized-mutable ^objects accs]
  AggState
  (grow [_ size] (set! accs (grow-objects accs size)))
  (update [this gids arg sel n]
    (let [^Vec arg arg]
      (each-sel [i sel n]
        (.add ^Accumulator (.acc this (aget gids i)) (when arg (.getObj arg i))))))
  (mergeFrom [this other from to]
    (.merge ^Accumulator (.acc this to) (.acc ^AccState other from)))
  (result [this gid] (.result ^Accumulator (.acc this gid)))
  Accs
  (acc [_ g]
    (or (aget accs g)
        (let [a (factory)] (aset accs g a) a))))

(defn agg-state
  "A fresh aggregate state for aggregate spec (polyquery.sql.bound); lib:
  the native kernel library or nil."
  (^polyquery.exec.grouping.AggState [spec] (agg-state spec nil))
  (^polyquery.exec.grouping.AggState [{f :fn distinct? :distinct? arg :arg :as spec} lib]
   (let [at (:type arg)
         k (t/kind at)
         vbits (when lib (bits/bitmap))]
     (cond
       (= f :count-star) (CountState. true (long-array 16))
       (and distinct? (= :long (b/vec-kind at)))
       (DistinctLongState. (= f :count) (agg/accumulator-factory (assoc spec :distinct? false))
                           (object-array 16))
       distinct? (AccState. (agg/accumulator-factory spec) (object-array 16))
       (= f :count) (CountState. false (long-array 16))

       (and (#{:sum :avg} f) (#{:int64 :decimal} k) (t/long-repr? at))
       (LongSumState. (case [f k]
                        [:sum :int64] (fn [s _] (agg/int-sum-result s))
                        [:sum :decimal] (fn [s _] (agg/dec-sum-result s))
                        (let [scale (t/scale at)] (fn [s cnt] (agg/exact-avg-result s cnt scale))))
                      (long-array 16) (long-array 16) nil lib vbits)

       (and (#{:sum :avg} f) (= :float64 k))
       (DoubleSumState. (= f :avg) (double-array 16) (long-array 16))

       (and (#{:min :max} f) (= :long (b/vec-kind at)))
       (LongExtremeState. (if (= f :min) 1 -1) (long-array 16) (boolean-array 16) lib vbits)

       (and (#{:min :max} f) (= :float64 k))
       (DoubleExtremeState. (if (= f :min) 1 -1) (double-array 16) (boolean-array 16) lib vbits)

       :else (AccState. (agg/accumulator-factory spec) (object-array 16))))))

(defn merge-mapping
  "int[] mapping every group of table `from` to its group in table `into`
  (added there if new, in from's order)."
  ^ints [^GroupTable into ^GroupTable from]
  (let [n (.size from)
        out (int-array n)]
    (if (and (instance? LongKeyTable into) (instance? LongKeyTable from))
      (let [^LongKeyTable t into ^LongKeyTable f from
            null-gid (.nullGid f)]
        (dotimes [g n]
          (aset out g (int (if (= g null-gid)
                             (.findOrAdd t (object-array 1))
                             (.lookup t (.keyLong f g)))))))
      (dotimes [g n]
        (aset out g (int (.findOrAdd into (.keyAt from g))))))
    out))
