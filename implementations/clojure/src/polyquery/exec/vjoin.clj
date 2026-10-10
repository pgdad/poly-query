(ns polyquery.exec.vjoin
  "Vectorized hash-join probe (`mode: vectorized`).

  The build input is hashed exactly like the row engine's hash join
  (polyquery.exec.join/build-hash-table — also shared by parallel
  partitions). The probe input arrives as batches: the probe keys are
  evaluated as vectors, every selected row is looked up, and the matches
  are written as (probe position, build row) pairs into output batches of
  up to 1,024 rows: probe-side columns are gathered from the typed probe
  vectors, build-side columns are LazyCols over the matched build rows
  (converted to typed vectors only if read). A residual condition (INNER
  joins) is evaluated as a kernel over each output batch.

  A single INT64/DECIMAL/DATE/TIMESTAMP key uses a primitive table
  instead: an open-addressing long → key id map (polyquery.exec.grouping)
  plus the build rows of every key chained through int arrays, so probing
  a batch neither boxes keys nor calls equals.

  Used for INNER joins and for LEFT joins without residual condition; LEFT
  joins with a residual condition (which decides per probe row whether it
  matched at all) use the row operator."
  (:require [polyquery.errors :as err]
            [polyquery.exec.batch :as b]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.exec.grouping :as g]
            [polyquery.exec.join :as join]
            [polyquery.exec.kernels :as k]
            [polyquery.exec.operators :as ops]
            [polyquery.exec.vectorized :as vectorized]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.util ArrayList HashMap)
           (polyquery.exec.batch Batch BoolVec DictVec DoubleVec LazyCol LongVec ObjVec Vec)
           (polyquery.exec.grouping LongKeyTable)
           (polyquery.exec.kernels Kernel)))

(set! *warn-on-reflection* true)

(defn vectorizable?
  "True when the vectorized probe implements this hash-join node."
  [plan]
  (or (= :inner (:join-type plan))
      (and (= :left (:join-type plan)) (nil? (:residual plan)) (not= :left (:build plan)))))

(defn- gather
  "Vector of v's values at positions pos[0..n)."
  ^polyquery.exec.batch.Vec [^Vec v ^ints pos ^long n]
  (let [take-nulls (fn [^booleans nulls]
                     (when nulls
                       (let [out (boolean-array b/capacity)]
                         (dotimes [i n] (aset out i (aget nulls (aget pos i))))
                         out)))]
    (cond
      (instance? LongVec v)
      (let [src ^longs (.-v ^LongVec v) out (long-array b/capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (LongVec. out (take-nulls (.-nulls ^LongVec v))))
      (instance? DoubleVec v)
      (let [src ^doubles (.-v ^DoubleVec v) out (double-array b/capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (DoubleVec. out (take-nulls (.-nulls ^DoubleVec v))))
      (instance? BoolVec v)
      (let [src ^booleans (.-v ^BoolVec v) out (boolean-array b/capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (BoolVec. out (take-nulls (.-nulls ^BoolVec v))))
      (instance? DictVec v)
      (let [src ^ints (.-codes ^DictVec v) out (int-array b/capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (DictVec. out (.-dict ^DictVec v) (take-nulls (.-nulls ^DictVec v))))
      (instance? LazyCol v)
      (let [src ^objects (.-rows ^LazyCol v) out (object-array n)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (LazyCol. out (.-col ^LazyCol v) nil))
      :else
      (let [out (object-array b/capacity)]
        (dotimes [i n] (aset out i (.getObj v (aget pos i))))
        (ObjVec. out)))))

;; ---------------------------------------------------------------------------
;; Primitive join table for one integer-like key

(deftype LongJoinTable [^LongKeyTable ids ^ints heads ^ints nexts ^objects rows])

(defn- key-factor
  "Multiplier converting a non-NULL value of type `from` to the long key of
  comparison type ct (nil when the key is not a plain long)."
  [from ct]
  (let [fk (t/kind from) ck (t/kind ct)]
    (cond
      (= fk ck :int64) 1
      (and (= ck :timestamp) (= fk :timestamp)) 1
      (and (= ck :timestamp) (= fk :date)) v/micros-per-day
      (and (= ck :date) (= fk :date)) 1
      (and (= ck :decimal) (#{:int64 :decimal} fk)) (v/dec-rescale-up 1 (- (t/scale ct) (t/scale from)))
      :else nil)))

(defn- scaled
  "x * f, or nil on overflow."
  [^long x ^long f]
  (if (= f 1)
    x
    (let [hi (Math/multiplyHigh x f) r (unchecked-multiply x f)]
      (when (== hi (bit-shift-right r 63)) r))))

(defn- long-key-spec
  "[build-key probe-key] of a join with one integer-like key, else nil."
  [plan]
  (let [build-left? (= :left (:build plan))
        [bk] (if build-left? (:left-keys plan) (:right-keys plan))
        [pk] (if build-left? (:right-keys plan) (:left-keys plan))]
    (when (and (= 1 (count (:left-keys plan)))
               (key-factor (:type (:expr bk)) (:cmp-type bk))
               (key-factor (:type (:expr pk)) (:cmp-type pk)))
      [bk pk])))

(defn build-table
  "The hash table of a hash-join node's build input for the vectorized
  probe: a LongJoinTable when the key allows, else the row engine's
  HashMap (polyquery.exec.join/build-hash-table)."
  [plan env]
  (if-let [[bk] (long-key-spec plan)]
    (let [build-left? (= :left (:build plan))
          rows (ops/materialize (ops/build-input (if build-left? (:left plan) (:right plan)) env) env)
          n (.size rows)
          kf (expr/compile-expr env (:expr bk))
          factor (long (key-factor (:type (:expr bk)) (:cmp-type bk)))
          ids (g/long-key-table)
          heads (int-array n -1)
          tails (int-array n -1)
          nexts (int-array n -1)
          ok? (loop [r 0]
                (if (= r n)
                  true
                  (let [x (kf (.get rows r))]
                    (if (nil? x)
                      (recur (inc r))
                      (if-some [key (scaled (long x) factor)]
                        (let [gid (.lookup ids (long key))]
                          (if (neg? (aget heads gid))
                            (aset heads gid (int r))
                            (aset nexts (aget tails gid) (int r)))
                          (aset tails gid (int r))
                          (recur (inc r)))
                        false)))))]
      (if ok?
        (LongJoinTable. ids heads nexts (.toArray rows))
        (join/hash-table rows (join/key-extractor env (if build-left? (:left-keys plan) (:right-keys plan)))
                         env)))
    (join/build-hash-table plan env)))

(defn- probe-keys
  "(fn [batch]) → Object[] of the hashable probe key of every selected
  position (nil when a key value is NULL), as the row engine computes it."
  [env keys]
  (let [ks (mapv (fn [{e :expr ct :cmp-type}] [(k/compile-kernel env e) (v/key-fn (:type e) ct)]) keys)
        nkeys (count ks)]
    (fn [^Batch bt]
      (let [sel (.-sel bt)
            n (.-n bt)
            vecs (mapv (fn [[kk _]] (k/ev kk bt sel n)) ks)
            kfs (mapv second ks)
            out (object-array b/capacity)]
        (if (= 1 nkeys)
          (let [^Vec x (first vecs) kf (first kfs)]
            (b/each-sel [i sel n]
              (let [y (.getObj x i)]
                (when (some? y) (aset out i (kf y))))))
          (b/each-sel [i sel n]
            (let [vals (object-array nkeys)
                  ok (loop [j 0]
                       (if (< j nkeys)
                         (let [y (.getObj ^Vec (nth vecs j) i)]
                           (when (some? y)
                             (aset vals j ((nth kfs j) y))
                             (recur (inc j))))
                         true))]
              (when ok (aset out i (vec vals))))))
        out))))

(defn- probe-long
  "Probes the selected rows of batch bt in a LongJoinTable, calling
  (add acc bt position build-row) per match (and per unmatched row of a
  LEFT join, with empty-row)."
  [^LongJoinTable table [pk factor] ^Batch bt add left-join? empty-row acc]
  (let [^LongKeyTable ids (.-ids table)
        ^ints heads (.-heads table)
        ^ints nexts (.-nexts table)
        ^objects rows (.-rows table)
        ^ints sel (.-sel bt)
        n (.-n bt)
        factor (long factor)
        ^LongVec x (k/ev pk bt sel n)
        vals ^longs (.-v x)
        nulls ^booleans (.-nulls x)]
    (loop [i 0 acc acc]
      (if (or (= i n) (reduced? acc))
        acc
        (let [p (aget sel i)
              key (when-not (b/nulls-at? nulls p) (scaled (aget vals p) factor))
              gid (if (nil? key) -1 (.find ids (long key)))]
          (if (neg? gid)
            (recur (inc i) (if left-join? (add acc bt p empty-row) acc))
            (recur (inc i)
                   (loop [r (aget heads gid) acc acc]
                     (if (or (neg? r) (reduced? acc))
                       acc
                       (recur (aget nexts r) (add acc bt p (aget rows r))))))))))))

(defmethod vectorized/build-batches :hash-join [plan env]
  (if-not (vectorizable? plan)
    (vectorized/rows->batches (ops/build plan env))
    (let [build-left? (= :left (:build plan))
          probe-plan (if build-left? (:right plan) (:left plan))
          probe (vectorized/build-batches probe-plan env)
          lw (long (:left-width plan))
          rw (long (:right-width plan))
          probe-offset (if build-left? lw 0)
          build-offset (if build-left? 0 lw)
          build-width (if build-left? lw rw)
          left-join? (= :left (:join-type plan))
          keys-of (probe-keys env (if build-left? (:right-keys plan) (:left-keys plan)))
          long-probe (when-let [[_ pk] (long-key-spec plan)]
                       [(k/compile-kernel env (:expr pk))
                        (key-factor (:type (:expr pk)) (:cmp-type pk))])
          residual (when-let [r (:residual plan)] (k/compile-filter env r))
          limit (long (or (:max-join-rows env) Long/MAX_VALUE))
          qctx (:ctx env)
          empty-row (object-array build-width)]
      (ops/reducible
       (fn [f init]
         (let [table (or (:prebuilt plan) (build-table plan env))
               produced (long-array 1)
               pos (int-array b/capacity)
               brows (object-array b/capacity)
               cnt (long-array 1)
               ;; emits the pending pairs of probe batch bt as one batch
               flush (fn [acc ^Batch bt]
                       (let [n (aget cnt 0)]
                         (if (zero? n)
                           acc
                           (let [^objects pcols (.-cols bt)
                                 cols (object-array (+ lw rw))
                                 rows (java.util.Arrays/copyOf brows (int n))]
                             (dotimes [c (alength pcols)]
                               (when-let [pv (aget pcols c)]
                                 (aset cols (+ probe-offset c) (gather pv pos n))))
                             (dotimes [c build-width]
                               (aset cols (+ build-offset c) (LazyCol. rows c nil)))
                             (aset cnt 0 0)
                             (let [out (Batch. cols b/identity-sel n)
                                   [sel m] (if residual (residual out) [b/identity-sel n])
                                   m (long m)
                                   total (+ (aget produced 0) m)]
                               (aset produced 0 total)
                               (when (> total limit)
                                 (err/fail! "RESOURCE_LIMIT"
                                            (str "join produced more than " limit " rows (--max-join-rows)")))
                               (ctx/check! qctx)
                               (if (zero? m) acc (f acc (Batch. cols sel m))))))))
               add (fn [acc bt ^long p r]
                     (let [c (aget cnt 0)]
                       (aset pos c (int p))
                       (aset brows c r)
                       (aset cnt 0 (inc c))
                       (if (= (inc c) b/capacity) (flush acc bt) acc)))]
           (reduce
            (fn [acc ^Batch bt]
              (let [^ints sel (.-sel bt)
                    n (.-n bt)
                    acc (if (instance? LongJoinTable table)
                          (probe-long table long-probe bt add left-join? empty-row acc)
                          (let [^HashMap table table
                                ^objects pkeys (keys-of bt)]
                            (loop [i 0 acc acc]
                            (if (or (= i n) (reduced? acc))
                              acc
                              (let [p (aget sel i)
                                    kv (aget pkeys p)
                                    ^ArrayList bucket (when (some? kv) (.get table kv))]
                                (cond
                                  bucket (recur (inc i)
                                                (loop [j 0 acc acc]
                                                  (if (or (= j (.size bucket)) (reduced? acc))
                                                    acc
                                                    (recur (inc j) (add acc bt p (.get bucket j))))))
                                  left-join? (recur (inc i) (add acc bt p empty-row))
                                  :else (recur (inc i) acc)))))))]
                (if (reduced? acc) acc (flush acc bt))))
            init probe)))))))

(defmethod vectorized/build-rows :hash-join [plan env]
  (if (vectorizable? plan)
    (vectorized/batches->rows (vectorized/build-batches plan env))
    (ops/build plan env)))
