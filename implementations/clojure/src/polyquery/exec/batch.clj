(ns polyquery.exec.batch
  "Column batches for vectorized execution (spec/phases/phase-5.md).

  A Batch holds up to `capacity` rows as one typed vector per FROM-row
  position (nil for positions nobody reads) plus a *selection vector*: the
  positions of the rows that are still alive, in ascending order. Filters
  only shrink the selection; vectors are never compacted.

  Vector representations by type kind (every value of one expression has the
  same representation, so kernels are specialised statically):
    INT64 DATE TIMESTAMP          LongVec   long[] values
    narrow DECIMAL (p <= 18)      LongVec   long[] unscaled values
    FLOAT64                       DoubleVec double[] values
    BOOLEAN                       BoolVec   boolean[] values
    STRING (and the NULL type)    ObjVec    Object[] values (nil = NULL), or
                                  DictVec   int[] codes into a dictionary
    wide DECIMAL (p > 18)         ObjVec    BigInteger unscaled values
  Typed vectors carry a boolean[] null mask, nil when no selected row is
  NULL. Only the selected positions of a vector are meaningful.

  LazyCol is a column of a batch built from row tuples (rows → batch
  adapter); it is converted to the typed representation on first use."
  (:require [polyquery.storage.column :as col]
            [polyquery.types :as t])
  (:import (java.nio ByteBuffer)
           (polyquery.storage.column BooleanVector BufferDoubleVector BufferIntVector
                                     BufferLongVector ColumnVector DictVector DoubleVector
                                     LongVector StringVector)))

(set! *warn-on-reflection* true)

(def ^:const capacity
  "Rows per batch: 8 KiB per LongVec, small enough to stay in L1/L2."
  1024)

(def ^ints identity-sel
  "Selection of all positions 0..capacity-1 (shared, never mutated)."
  (int-array (range capacity)))

(definterface Vec
  (getObj [^long i] "Runtime value at position i (nil for NULL).")
  (^boolean isNullAt [^long i])
  (setObj [^long i x] "Stores a runtime value (vectors built with a null mask only)."))

(deftype LongVec [^longs v ^booleans nulls]
  Vec
  (getObj [_ i] (when-not (and nulls (aget nulls i)) (aget v i)))
  (isNullAt [_ i] (boolean (and nulls (aget nulls i))))
  (setObj [_ i x] (if (nil? x) (aset nulls i true) (do (aset nulls i false) (aset v i (long x))))))

(deftype DoubleVec [^doubles v ^booleans nulls]
  Vec
  (getObj [_ i] (when-not (and nulls (aget nulls i)) (aget v i)))
  (isNullAt [_ i] (boolean (and nulls (aget nulls i))))
  (setObj [_ i x] (if (nil? x) (aset nulls i true) (do (aset nulls i false) (aset v i (double x))))))

(deftype BoolVec [^booleans v ^booleans nulls]
  Vec
  (getObj [_ i] (when-not (and nulls (aget nulls i)) (if (aget v i) Boolean/TRUE Boolean/FALSE)))
  (isNullAt [_ i] (boolean (and nulls (aget nulls i))))
  (setObj [_ i x] (if (nil? x) (aset nulls i true) (do (aset nulls i false) (aset v i (boolean x))))))

(deftype ObjVec [^objects v]
  Vec
  (getObj [_ i] (aget v i))
  (isNullAt [_ i] (nil? (aget v i)))
  (setObj [_ i x] (aset v i x)))

(deftype DictVec [^ints codes ^objects dict ^booleans nulls]
  Vec
  (getObj [_ i] (when-not (and nulls (aget nulls i)) (aget dict (aget codes i))))
  (isNullAt [_ i] (boolean (and nulls (aget nulls i))))
  (setObj [_ _ _] (throw (UnsupportedOperationException. "DictVec is read-only"))))

(deftype Batch [^objects cols ^ints sel ^long n])

(defmacro each-sel
  "Runs body for every selected position i (bound to a long) of selection
  `sel` with `n` entries; the identity selection gets a direct loop, which
  the JIT can unroll and vectorize."
  [[i sel n] & body]
  `(let [sel# ~sel n# (long ~n)]
     (if (identical? sel# identity-sel)
       (dotimes [~i n#] ~@body)
       (dotimes [k# n#] (let [~i (long (aget ^"[I" sel# k#))] ~@body)))))

(defmacro nulls-at?
  "True when null mask `nulls` (possibly nil) marks position i as NULL."
  [nulls i]
  (let [m (gensym "nulls")]
    `(let [~m ~nulls] (boolean (if (nil? ~m) false (aget ~(with-meta m {:tag "[Z"}) ~i))))))

;; ---------------------------------------------------------------------------
;; Construction

(defn vec-kind
  "Vector representation of a type: :long :double :bool or :obj."
  [type]
  (case (t/kind type)
    (:int64 :date :timestamp) :long
    :decimal (if (t/wide? type) :obj :long)
    :float64 :double
    :boolean :bool
    (:string :null) :obj))

(defn new-vec
  "Empty writable vector (with a null mask) for values of `type`."
  ^polyquery.exec.batch.Vec [type]
  (case (vec-kind type)
    :long (LongVec. (long-array capacity) (boolean-array capacity))
    :double (DoubleVec. (double-array capacity) (boolean-array capacity))
    :bool (BoolVec. (boolean-array capacity) (boolean-array capacity))
    :obj (ObjVec. (object-array capacity))))

(defn constant-vec
  "Vector holding value x at every position."
  ^polyquery.exec.batch.Vec [type x]
  (let [nulls (when (nil? x) (doto (boolean-array capacity) (java.util.Arrays/fill true)))]
    (case (vec-kind type)
      :long (LongVec. (doto (long-array capacity) (java.util.Arrays/fill (long (or x 0)))) nulls)
      :double (DoubleVec. (doto (double-array capacity) (java.util.Arrays/fill (double (or x 0.0)))) nulls)
      :bool (BoolVec. (doto (boolean-array capacity) (java.util.Arrays/fill (boolean x))) nulls)
      :obj (ObjVec. (doto (object-array capacity) (java.util.Arrays/fill ^Object x))))))

(defn obj-vec
  "The selected values of v as an ObjVec (materializes dictionary codes)."
  ^polyquery.exec.batch.ObjVec [^Vec v ^ints sel ^long n]
  (if (instance? ObjVec v)
    v
    (let [out (object-array capacity)]
      (each-sel [i sel n] (aset out i (.getObj v i)))
      (ObjVec. out))))

;; ---------------------------------------------------------------------------
;; Selections

(defn true-positions
  "Selection of the positions in (sel, n) where the boolean vector is TRUE
  (not FALSE, not NULL). Returns [sel' n'] as a Batch-less pair."
  [^BoolVec b ^ints sel ^long n]
  (let [v ^booleans (.-v b)
        nulls ^booleans (.-nulls b)
        out (int-array n)
        cnt (if nulls
              (loop [k 0 c 0]
                (if (< k n)
                  (let [i (aget sel k)]
                    (if (and (aget v i) (not (aget nulls i)))
                      (do (aset out c i) (recur (inc k) (inc c)))
                      (recur (inc k) c)))
                  c))
              (loop [k 0 c 0]
                (if (< k n)
                  (let [i (aget sel k)]
                    (aset out c i)
                    ;; branch-free compaction
                    (recur (inc k) (if (aget v i) (inc c) c)))
                  c)))]
    [out cnt]))

(defn positions-where
  "Sub-selection of (sel, n) of the positions for which (keep? i) is true."
  [^ints sel ^long n keep?]
  (let [out (int-array n)
        cnt (loop [k 0 c 0]
              (if (< k n)
                (let [i (aget sel k)]
                  (if (keep? i)
                    (do (aset out c i) (recur (inc k) (inc c)))
                    (recur (inc k) c)))
                c))]
    [out cnt]))

;; ---------------------------------------------------------------------------
;; Table segments → batches

(defn arena
  "Per-column buffer arena of a scan: the scan's batches reuse the same
  arrays (a consumer never retains a scan batch past its reduction step:
  rows, aggregate states and join tables copy the values they keep), which
  removes per-batch allocation and zeroing."
  ^objects []
  (object-array 6))

(defmacro ^:private buffer
  "Array in slot `slot` of arena a (nil: a fresh array), created by ctor."
  [a slot ctor tag]
  (let [x (gensym "a") y (gensym "buf")]
    `(let [~x ~a]
       (if (nil? ~x)
         ~ctor
         (or (aget ~(with-meta x {:tag "[Ljava.lang.Object;"}) ~slot)
             (let [~y ~ctor] (aset ~(with-meta x {:tag "[Ljava.lang.Object;"}) ~slot ~y) ~y))))))

(defn- copy-nulls
  "Null mask of rows [start, start+n) from a validity bitmap (nil if none)."
  ^booleans [^longs validity ^long start ^long n a]
  (when validity
    (let [^booleans out (buffer a 5 (boolean-array capacity) "[Z")]
      (loop [i 0 any? false]
        (if (< i n)
          (let [nul (not (col/bit-set? validity (+ start i)))]
            (aset out i nul)
            (recur (inc i) (or any? nul)))
          (when any? out))))))

(defn- generic-vec
  "Vector of rows [start, start+n) of any ColumnVector."
  [^ColumnVector cv type ^long start ^long n]
  (let [out (new-vec type)]
    (dotimes [i n] (.setObj out i (.valueAt cv (+ start i))))
    out))

(defn segment-vec
  "Vector of rows [start, start+n) of a column vector of the given type,
  with its arrays taken from arena a (nil: fresh arrays). The in-memory
  typed vectors are copied with System/arraycopy; dictionary vectors keep
  their codes."
  ^polyquery.exec.batch.Vec [^ColumnVector cv type start n a]
  (let [start (long start) n (long n)]
    (cond
      (instance? LongVector cv)
      (let [^LongVector lv cv
            ^longs out (buffer a 0 (long-array capacity) "[J")]
        (System/arraycopy ^longs (.-values lv) start out 0 n)
        (LongVec. out (copy-nulls (.-validity lv) start n a)))

      (instance? DoubleVector cv)
      (let [^DoubleVector dv cv
            ^doubles out (buffer a 1 (double-array capacity) "[D")]
        (System/arraycopy ^doubles (.-values dv) start out 0 n)
        (DoubleVec. out (copy-nulls (.-validity dv) start n a)))

      (instance? DictVector cv)
      (let [^DictVector dv cv
            ^ints out (buffer a 2 (int-array capacity) "[I")]
        (System/arraycopy ^ints (.-codes dv) start out 0 n)
        (DictVec. out (.-dict dv) (copy-nulls (.-validity dv) start n a)))

      (instance? StringVector cv)
      (let [^StringVector sv cv
            ^objects out (buffer a 3 (object-array capacity) "[Ljava.lang.Object;")]
        (System/arraycopy ^objects (.-values sv) start out 0 n)
        (ObjVec. out))

      (instance? BooleanVector cv)
      (let [^BooleanVector bv cv
            bits ^longs (.-bits bv)
            ^booleans out (buffer a 4 (boolean-array capacity) "[Z")]
        (dotimes [i n] (aset out i (boolean (col/bit-set? bits (+ start i)))))
        (BoolVec. out (copy-nulls (.-validity bv) start n a)))

      (instance? BufferLongVector cv)
      (let [^BufferLongVector bv cv
            ^ByteBuffer buf (.-buf bv)
            base (+ (.-base bv) (* 8 start))
            ^longs out (buffer a 0 (long-array capacity) "[J")]
        (dotimes [i n] (aset out i (.getLong buf (int (+ base (* 8 i))))))
        (LongVec. out (copy-nulls (.-validity bv) start n a)))

      (instance? BufferIntVector cv)
      (let [^BufferIntVector bv cv
            ^ByteBuffer buf (.-buf bv)
            base (+ (.-base bv) (* 4 start))
            ^longs out (buffer a 0 (long-array capacity) "[J")]
        (dotimes [i n] (aset out i (long (.getInt buf (int (+ base (* 4 i)))))))
        (LongVec. out (copy-nulls (.-validity bv) start n a)))

      (instance? BufferDoubleVector cv)
      (let [^BufferDoubleVector bv cv
            ^ByteBuffer buf (.-buf bv)
            base (+ (.-base bv) (* 8 start))
            ^doubles out (buffer a 1 (double-array capacity) "[D")]
        (dotimes [i n] (aset out i (.getDouble buf (int (+ base (* 8 i))))))
        (DoubleVec. out (copy-nulls (.-validity bv) start n a)))

      :else (generic-vec cv type start n))))

;; ---------------------------------------------------------------------------
;; Rows ↔ batches

(definterface Typed
  (typedVec [type] "The column in its typed representation (cached)."))

(deftype LazyCol [^objects rows ^long col ^:unsynchronized-mutable typed]
  Vec
  (getObj [_ i] (aget ^objects (aget rows i) col))
  (isNullAt [_ i] (nil? (aget ^objects (aget rows i) col)))
  (setObj [_ _ _] (throw (UnsupportedOperationException. "LazyCol is read-only")))
  Typed
  (typedVec [_ type]
    (or typed
        (let [out (new-vec type)]
          (dotimes [i (alength rows)] (.setObj out i (aget ^objects (aget rows i) col)))
          (set! typed out)
          out))))

(defn- rows-vec
  "Column `col` of all the row tuples as one typed vector of their length:
  STRING columns dictionary-encoded unless most values are distinct."
  ^polyquery.exec.batch.Vec [^objects rows ^long col type]
  (let [n (alength rows)
        value (fn [^long r] (aget ^objects (aget rows r) col))
        nulls (let [m (boolean-array n)]
                (when (loop [r 0 any? false]
                        (if (< r n)
                          (let [nul (nil? (value r))] (aset m r nul) (recur (inc r) (or any? nul)))
                          any?))
                  m))]
    (case (vec-kind type)
      :long (let [v (long-array n)]
              (dotimes [r n] (when-some [x (value r)] (aset v r (long x))))
              (LongVec. v nulls))
      :double (let [v (double-array n)]
                (dotimes [r n] (when-some [x (value r)] (aset v r (double x))))
                (DoubleVec. v nulls))
      :bool (let [v (boolean-array n)]
              (dotimes [r n] (when-some [x (value r)] (aset v r (boolean x))))
              (BoolVec. v nulls))
      :obj (let [codes (int-array n)
                 ids (java.util.HashMap.)
                 dict (java.util.ArrayList.)
                 max-dict (+ 16 (quot n 2))
                 encoded? (and (= :string (t/kind type))
                               (loop [r 0]
                                 (cond
                                   (= r n) true
                                   (> (.size dict) max-dict) false
                                   :else (let [x (value r)]
                                           (when (some? x)
                                             (let [c (.get ids x)]
                                               (aset codes r (int (if (some? c)
                                                                    c
                                                                    (let [c (.size dict)]
                                                                      (.put ids x (Integer/valueOf c))
                                                                      (.add dict x)
                                                                      c))))))
                                           (recur (inc r))))))]
             (if encoded?
               (DictVec. codes (.toArray dict) nulls)
               (let [v (object-array n)]
                 (dotimes [r n] (aset v r (value r)))
                 (ObjVec. v)))))))

(deftype RowsColumn [^objects rows ^long col ^:volatile-mutable typed]
  ;; column `col` of row tuples, converted once (thread-safely) to a typed
  ;; vector over all rows on first typed use — e.g. a hash join's build side,
  ;; shared by parallel partitions
  Vec
  (getObj [_ i] (aget ^objects (aget rows i) col))
  (isNullAt [_ i] (nil? (aget ^objects (aget rows i) col)))
  (setObj [_ _ _] (throw (UnsupportedOperationException. "RowsColumn is read-only")))
  Typed
  (typedVec [this type]
    (or typed
        (locking this
          (or typed
              (let [v (rows-vec rows col type)]
                (set! typed v)
                v))))))

(defn gather-vec
  "Vector of v's values at positions pos[0..n): typed vectors stay typed
  (dictionary codes are gathered)."
  ^polyquery.exec.batch.Vec [^Vec v ^ints pos ^long n]
  (let [take-nulls (fn [^booleans nulls]
                     (when nulls
                       (let [out (boolean-array capacity)]
                         (dotimes [i n] (aset out i (aget nulls (aget pos i))))
                         out)))]
    (cond
      (instance? LongVec v)
      (let [src ^longs (.-v ^LongVec v) out (long-array capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (LongVec. out (take-nulls (.-nulls ^LongVec v))))
      (instance? DoubleVec v)
      (let [src ^doubles (.-v ^DoubleVec v) out (double-array capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (DoubleVec. out (take-nulls (.-nulls ^DoubleVec v))))
      (instance? BoolVec v)
      (let [src ^booleans (.-v ^BoolVec v) out (boolean-array capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (BoolVec. out (take-nulls (.-nulls ^BoolVec v))))
      (instance? DictVec v)
      (let [src ^ints (.-codes ^DictVec v) out (int-array capacity)]
        (dotimes [i n] (aset out i (aget src (aget pos i))))
        (DictVec. out (.-dict ^DictVec v) (take-nulls (.-nulls ^DictVec v))))
      :else
      (let [out (object-array capacity)]
        (dotimes [i n] (aset out i (.getObj v (aget pos i))))
        (ObjVec. out)))))

(deftype GatherCol [^Vec src ^ints pos ^long n ^:unsynchronized-mutable typed]
  ;; the values of src at positions pos[0..n), gathered from src's typed
  ;; representation on first typed use
  Vec
  (getObj [_ i] (.getObj src (aget pos i)))
  (isNullAt [_ i] (.isNullAt src (aget pos i)))
  (setObj [_ _ _] (throw (UnsupportedOperationException. "GatherCol is read-only")))
  Typed
  (typedVec [_ type]
    (or typed
        (let [v (gather-vec (if (instance? Typed src) (.typedVec ^Typed src type) src) pos n)]
          (set! typed v)
          v))))

(defn gather-col
  "Lazy column of v's values at positions pos[0..n) (pos is retained)."
  ^polyquery.exec.batch.Vec [^Vec v ^ints pos ^long n]
  (if (instance? GatherCol v)
    (let [^GatherCol g v
          ^ints inner (.-pos g)
          out (int-array n)]
      (dotimes [i n] (aset out i (aget inner (aget pos i))))
      (GatherCol. (.-src g) out n nil))
    (GatherCol. v pos n nil)))

(defn typed-column
  "The column vector at position idx of a batch in its typed representation
  (forces a LazyCol, RowsColumn or GatherCol)."
  ^polyquery.exec.batch.Vec [^Batch b ^long idx type]
  (let [v (aget ^objects (.-cols b) idx)]
    (if (instance? Typed v)
      (.typedVec ^Typed v type)
      v)))

(defn rows->batch
  "Batch over the row tuples in `rows` (at most `capacity`, all selected);
  every column position is a LazyCol."
  ^Batch [^objects rows ^long n ^long width]
  (let [cols (object-array width)]
    (dotimes [c width] (aset cols c (LazyCol. rows c nil)))
    (Batch. cols identity-sel n)))

(defn batch-rows!
  "Calls (emit row) for each selected row of the batch as an Object array of
  the batch width; returns the last value of emit or `reduced`."
  [^Batch b f init]
  (let [^objects cols (.-cols b)
        width (alength cols)
        ^ints sel (.-sel b)
        n (.-n b)]
    (loop [k 0 acc init]
      (if (or (= k n) (reduced? acc))
        acc
        (let [i (aget sel k)
              row (object-array width)]
          (dotimes [c width]
            (when-let [v (aget cols c)]
              (aset row c (.getObj ^Vec v i))))
          (recur (inc k) (f acc row)))))))
