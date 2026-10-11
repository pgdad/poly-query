(ns polyquery.exec.native
  "Vectorized filters on native kernels (`native: true`,
  spec/phases/native-kernels.md).

  A WHERE / join-residual predicate is split into its top-level conjuncts.
  The conjuncts built only from

    integer-like column  op  constant        (=, <>, <, <=, >, >=)
    integer-like column  BETWEEN c1 AND c2   (also NOT BETWEEN)
    integer-like column  [NOT] IN (constants)  (at most 16 items)
    integer-like column  op  integer-like column  (same domain)
    column IS [NOT] NULL, a BOOLEAN column, TRUE / FALSE / NULL
    and AND / OR / NOT over these

  (integer-like: INT64, DATE, TIMESTAMP and DECIMAL as unscaled longs; the
  constant converted to the column's domain exactly as the Java kernels do,
  polyquery.exec.kernels) are evaluated per batch into a bitmap of the rows
  where they are TRUE: pqk_filter_i64_bitmap / pqk_compare_i64 per leaf,
  pqk_bitmap_and / _or / _andnot to combine leaves and validity, and the
  bitmap is converted into the batch's new selection vector. NOT is pushed
  down to the leaves at compile time (De Morgan, inverted operators), which
  is exact in three-valued logic. A lone column/constant comparison over a
  full batch uses pqk_filter_i64, which writes the selection directly.

  The remaining conjuncts are evaluated by the Java kernels on the rows the
  native part kept. None of the native conjuncts can fail, so this only
  changes how much work is done — except that the row engine evaluates a
  conjunct on rows where earlier ones are NULL: when a remaining conjunct
  could fail, the whole predicate stays on the Java kernels, so errors are
  exactly those of the row engine."
  (:require [polyquery.exec.batch :as b]
            [polyquery.exec.kernels :as k]
            [polyquery.native.bits :as bits]
            [polyquery.native.ffi :as ffi]
            [polyquery.sql.bound :as bound]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (polyquery.exec.batch Batch BoolVec LongVec)
           (polyquery.native.ffi Library)))

(set! *warn-on-reflection* true)

(definterface Pred
  (eval [^polyquery.exec.batch.Batch bt ^ints sel ^long n ^long span
         ^"[Ljava.lang.Object;" scratch ^longs out]
        "Writes the bitmap of the positions [0, span) where the predicate is
        TRUE to out (positions outside the selection are don't-care)."))

(def ^:private op-codes
  {"=" ffi/EQ "<>" ffi/NE "<" ffi/LT "<=" ffi/LE ">" ffi/GT ">=" ffi/GE})

(def ^:private negated-op
  {"=" "<>" "<>" "=" "<" ">=" ">=" "<" "<=" ">" ">" "<="})

(def ^:private flipped-op
  {"=" "=" "<>" "<>" "<" ">" ">" "<" "<=" ">=" ">=" "<="})

(def ^:private max-in-items 16)

(defn- long-kind? [type] (= :long (b/vec-kind type)))

(defn- column? [e] (and (= :column (:node e)) (not= :null (t/kind (:type e)))))

(defn- non-null-literal? [e] (and (= :literal (:node e)) (some? (:value e))))

(defn- domain-constant
  "Constant c (of type ct) as a long comparable with the values of a column
  of type xt in comparison type cmp-type, or nil when the Java kernels do
  not compare them as plain longs (polyquery.exec.kernels/const-compare-kernel)."
  [cmp-type xt c ct]
  (let [k (t/kind cmp-type)]
    (cond
      (and (#{:int64 :date :timestamp} k) (= (t/kind ct) k) (= (t/kind xt) k))
      (long c)

      (and (= :decimal k) (= :decimal (t/kind xt)) (<= (t/scale ct) (t/scale xt)))
      (let [r (v/dec-rescale-up (long c) (- (t/scale xt) (t/scale ct)))]
        (when (instance? Long r) r))

      :else nil)))

;; ---------------------------------------------------------------------------
;; Predicate tree

(defn- slot ^longs [^objects scratch ^long i] (aget scratch i))

(defn- column-long ^LongVec [^Batch bt ^long idx type]
  (b/typed-column bt idx type))

(defn- const-leaf
  "TRUE everywhere (on? true) or nowhere."
  [on?]
  (reify Pred
    (eval [_ _ _ _ span _ out] (bits/fill! out span on?))))

(defn- compare-const-leaf
  "column `op` (a, c) with pqk_filter_i64_bitmap (validity consulted)."
  [^Library lib idx type op a c alloc!]
  (let [vslot (long (alloc!)) idx (long idx) op (long op) a (long a) c (long c)]
    (reify Pred
      (eval [_ bt _ _ span scratch out]
        (let [x (column-long bt idx type)
              nulls ^booleans (.-nulls x)
              valid (when nulls (bits/valid-bits! nulls span (slot scratch vslot)))]
          (ffi/filter-i64-bitmap lib (.-v x) valid span op a c out))))))

(defn- compare-columns-leaf
  "column `op` column with pqk_compare_i64, AND the validity of both."
  [^Library lib li lt ri rt op alloc!]
  (let [vslot (long (alloc!)) li (long li) ri (long ri) op (long op)]
    (reify Pred
      (eval [_ bt _ _ span scratch out]
        (let [x (column-long bt li lt)
              y (column-long bt ri rt)
              nw (bits/nwords span)]
          (ffi/compare-i64 lib (.-v x) (.-v y) span op out)
          (doseq [^booleans nulls [(.-nulls x) (.-nulls y)] :when nulls]
            (ffi/bitmap-and! lib out (bits/valid-bits! nulls span (slot scratch vslot)) out nw)))))))

(defn- is-null-leaf
  "column IS NULL (want-null? true) / IS NOT NULL."
  [^Library lib idx type want-null? alloc!]
  (let [vslot (long (alloc!)) idx (long idx)]
    (reify Pred
      (eval [_ bt sel n span scratch out]
        (let [nulls (k/nulls-of (b/typed-column bt idx type) sel n)]
          (cond
            (nil? nulls) (bits/fill! out span (not want-null?))
            want-null? (let [valid (bits/valid-bits! nulls span (slot scratch vslot))]
                         (ffi/bitmap-andnot! lib (bits/fill! out span true) valid out (bits/nwords span)))
            :else (bits/valid-bits! nulls span out)))))))

(defn- bool-column-leaf
  "A BOOLEAN column is TRUE (negate? false) / FALSE."
  [^Library lib idx negate? alloc!]
  (let [vslot (long (alloc!)) idx (long idx)]
    (reify Pred
      (eval [_ bt _ _ span scratch out]
        (let [^BoolVec x (b/typed-column bt idx :boolean)
              nulls ^booleans (.-nulls x)]
          (bits/true-bits! (.-v x) span negate? out)
          (when nulls
            (ffi/bitmap-and! lib out (bits/valid-bits! nulls span (slot scratch vslot)) out
                             (bits/nwords span))))))))

(defn- combine
  "AND (and? true) / OR of child predicates."
  [^Library lib preds and? alloc!]
  (if (= 1 (count preds))
    (first preds)
    (let [^objects ps (into-array Object preds)
          tslot (long (alloc!))]
      (reify Pred
        (eval [_ bt sel n span scratch out]
          (let [tmp (slot scratch tslot)
                nw (bits/nwords span)]
            (.eval ^Pred (aget ps 0) bt sel n span scratch out)
            (loop [i 1]
              (when (< i (alength ps))
                (.eval ^Pred (aget ps i) bt sel n span scratch tmp)
                (if and?
                  (ffi/bitmap-and! lib out tmp out nw)
                  (ffi/bitmap-or! lib out tmp out nw))
                (recur (inc i))))))))))

(declare compile-pred)

(defn- compare-pred
  [lib e negated? alloc!]
  (let [{:keys [op cmp-type left right]} e
        op (if negated? (negated-op op) op)]
    (cond
      (= :null (t/kind cmp-type)) nil

      (and (column? left) (non-null-literal? right) (long-kind? (:type left)))
      (when-some [c (domain-constant cmp-type (:type left) (:value right) (:type right))]
        (compare-const-leaf lib (:index left) (:type left) (op-codes op) c 0 alloc!))

      (and (column? right) (non-null-literal? left) (long-kind? (:type right)))
      (when-some [c (domain-constant cmp-type (:type right) (:value left) (:type left))]
        (compare-const-leaf lib (:index right) (:type right) (op-codes (flipped-op op)) c 0 alloc!))

      (and (column? left) (column? right))
      (let [k (t/kind cmp-type) lt (:type left) rt (:type right)]
        (when (or (and (#{:int64 :date :timestamp} k) (= k (t/kind lt) (t/kind rt)))
                  (and (= :decimal k (t/kind lt) (t/kind rt)) (= (t/scale lt) (t/scale rt))))
          (compare-columns-leaf lib (:index left) lt (:index right) rt (op-codes op) alloc!)))

      :else nil)))

(defn- between-pred
  [lib e negated? alloc!]
  (let [{x :arg lo :low hi :high} e
        negated? (not= (boolean (:not? e)) (boolean negated?))]
    (when (and (column? x) (long-kind? (:type x)) (non-null-literal? lo) (non-null-literal? hi))
      (let [xt (:type x)
            a (domain-constant (:low-type e) xt (:value lo) (:type lo))
            c (domain-constant (:high-type e) xt (:value hi) (:type hi))]
        (when (and (some? a) (some? c))
          (if negated?
            (combine lib [(compare-const-leaf lib (:index x) xt ffi/LT a 0 alloc!)
                          (compare-const-leaf lib (:index x) xt ffi/GT c 0 alloc!)]
                     false alloc!)
            (compare-const-leaf lib (:index x) xt ffi/BETWEEN a c alloc!)))))))

(defn- in-list-pred
  [lib e negated? alloc!]
  (let [{x :arg items :items cmp-types :cmp-types} e
        negated? (not= (boolean (:not? e)) (boolean negated?))
        ct (first cmp-types)]
    (when (and (column? x) (long-kind? (:type x))
               (<= (count items) max-in-items)
               (every? #(= :literal (:node %)) items)
               (apply = cmp-types)
               (not= :null (t/kind ct)))
      (let [xt (:type x)
            has-null? (boolean (some #(nil? (:value %)) items))
            consts (for [item items :when (some? (:value item))]
                     (domain-constant ct xt (:value item) (:type item)))]
        (when (every? some? consts)
          (cond
            ;; x NOT IN (…, NULL, …) is never TRUE
            (and negated? has-null?) (const-leaf false)
            (empty? consts) (const-leaf false)
            :else (combine lib (mapv #(compare-const-leaf lib (:index x) xt (if negated? ffi/NE ffi/EQ)
                                                          % 0 alloc!)
                                     (distinct consts))
                           negated? alloc!)))))))

(defn- compile-pred
  "Pred of the rows where e (negated: NOT e) is TRUE, or nil when e has no
  native evaluation."
  [lib e negated? alloc!]
  (case (:node e)
    :not (compile-pred lib (:arg e) (not negated?) alloc!)

    (:and :or)
    (let [and? (not= (= :and (:node e)) (boolean negated?))
          ;; flatten chains of the same connective
          parts (loop [todo [e] out []]
                  (if-let [[x & more] (seq todo)]
                    (if (= (:node x) (:node e))
                      (recur (concat [(:left x) (:right x)] more) out)
                      (recur more (conj out x)))
                    out))
          preds (mapv #(compile-pred lib % negated? alloc!) parts)]
      (when (every? some? preds)
        (combine lib preds and? alloc!)))

    :compare (compare-pred lib e negated? alloc!)
    :between (between-pred lib e negated? alloc!)
    :in-list (in-list-pred lib e negated? alloc!)

    :is-null
    (when (column? (:arg e))
      (is-null-leaf lib (:index (:arg e)) (:type (:arg e))
                    ;; IS NULL, or NOT (… IS NOT NULL)
                    (= (boolean (:not? e)) (boolean negated?)) alloc!))

    :column
    (when (= :boolean (t/kind (:type e)))
      (bool-column-leaf lib (:index e) negated? alloc!))

    :literal
    (when (= :boolean (t/kind (:type e)))
      (let [x (:value e)]
        (const-leaf (and (some? x) (not= (boolean x) (boolean negated?))))))

    nil))

;; ---------------------------------------------------------------------------
;; Filters

(defn- scratch-pool
  "Per-thread scratch bitmaps: slot i of the Object[] is a batch bitmap."
  ^ThreadLocal [^long nslots]
  (ThreadLocal/withInitial
   (reify java.util.function.Supplier
     (get [_] (let [a (object-array nslots)]
                (dotimes [i nslots] (aset a i (bits/bitmap)))
                a)))))

(defn- single-compare
  "[column-index type op a c] when the native part is one column/constant
  comparison (evaluated with pqk_filter_i64 on full batches)."
  [lib conjunct]
  (let [{:keys [node op cmp-type left right]} conjunct]
    (when (and (= :compare node) (column? left) (non-null-literal? right)
               (long-kind? (:type left)) (not= :null (t/kind cmp-type)))
      (when-some [c (domain-constant cmp-type (:type left) (:value right) (:type right))]
        [(:index left) (:type left) (op-codes op) c 0]))))

(defn- native-filter
  "(fn [batch]) → [sel n] evaluating Pred p (plus the Java filter `rest`
  over the rows p keeps)."
  [^Library lib ^Pred p nslots single rest]
  (let [pool (scratch-pool (+ 2 (long nslots)))
        [sidx stype sop sa sc] single
        sidx (long (or sidx 0)) sop (long (or sop 0)) sa (long (or sa 0)) sc (long (or sc 0))
        apply-rest (fn [^Batch bt sel n]
                     (if (or (nil? rest) (zero? (long n)))
                       [sel n]
                       (rest (Batch. (.-cols bt) sel n))))]
    (fn [^Batch bt]
      (let [sel (.-sel bt)
            n (.-n bt)
            identity? (bits/identity-sel? sel)]
        (if (and single identity? (nil? (.-nulls (column-long bt sidx stype))))
          (let [x (column-long bt sidx stype)
                out (int-array n)
                cnt (ffi/filter-i64 lib (.-v x) nil n sop sa sc out)]
            (apply-rest bt (if (= cnt n) b/identity-sel out) cnt))
          (let [^objects scratch (.get pool)
                span (bits/span sel n)
                out (slot scratch 0)]
            (.eval p bt sel n span scratch out)
            (when-not identity?
              (ffi/bitmap-and! lib out (bits/sel-bits! sel n (slot scratch 1)) out (bits/nwords span)))
            (let [[sel2 n2] (bits/bitmap->sel out span identity?)]
              (apply-rest bt sel2 n2))))))))

(defn compile-filter
  "Compiles a predicate into (fn [batch]) → [sel n] of the rows where it is
  TRUE: on native kernels when env has a loaded library (:native) and the
  predicate allows (see the namespace doc), else the Java kernels
  (polyquery.exec.kernels/compile-filter)."
  [env e]
  (let [lib (:native env)]
    (or (when lib
          (let [nslots (volatile! 2)
                alloc! #(dec (long (vswap! nslots inc)))
                compiled (mapv (fn [c] [c (compile-pred lib c false alloc!)]) (bound/conjuncts e))
                natives (filterv second compiled)
                others (mapv first (remove second compiled))]
            (when (and (seq natives) (not-any? k/may-fail? others))
              (native-filter lib
                             (combine lib (mapv second natives) true alloc!)
                             @nslots
                             (when (= 1 (count natives)) (single-compare lib (first (first natives))))
                             (when (seq others) (k/compile-filter env (bound/conjoin others)))))))
        (k/compile-filter env e))))
