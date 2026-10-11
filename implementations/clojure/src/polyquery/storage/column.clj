(ns polyquery.storage.column
  "Typed column vectors (spec/storage/indexes-and-planning.md §1): one typed
  vector per column plus a validity (null) bitmap, dictionary encoding for
  STRING columns, a view of one column of a row-oriented table, and views
  over memory-mapped PQCF chunks.

  Every vector implements ColumnVector, whose `valueAt` returns the runtime
  value of a row (see polyquery.types) or nil for NULL.

  Validity bitmaps are long arrays, bit (i mod 64) of word (i / 64) is 1 for
  a non-null row i; a nil bitmap means \"no NULLs\"."
  (:require [polyquery.types :as t])
  (:import (java.nio ByteBuffer)
           (java.util HashMap)))

(set! *warn-on-reflection* true)

(definterface ColumnVector
  (^long size [])
  (^boolean isNull [^long i])
  (valueAt [^long i]))

;; ---------------------------------------------------------------------------
;; Bitmaps

(defn bitmap-words ^long [^long n] (unsigned-bit-shift-right (+ n 63) 6))

(defn bit-set? [^longs bits ^long i]
  (not (zero? (bit-and (aget bits (unsigned-bit-shift-right i 6))
                       (bit-shift-left 1 (bit-and i 63))))))

(defn set-bit! [^longs bits ^long i]
  (let [w (unsigned-bit-shift-right i 6)]
    (aset bits w (bit-or (aget bits w) (bit-shift-left 1 (bit-and i 63))))))

(defn- valid? [^longs validity ^long i]
  (or (nil? validity) (bit-set? validity i)))

(defn validity-of
  "Validity bitmap of an Object array of values (nil when there is no NULL)."
  ^longs [^objects vals]
  (let [n (alength vals)]
    (when (some nil? vals)
      (let [bits (long-array (bitmap-words n))]
        (dotimes [i n] (when (some? (aget vals i)) (set-bit! bits i)))
        bits))))

;; ---------------------------------------------------------------------------
;; In-memory vectors

(deftype LongVector [^longs values ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (aget values i))))

(deftype DoubleVector [^doubles values ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (aget values i))))

(deftype BooleanVector [^longs bits ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (if (bit-set? bits i) Boolean/TRUE Boolean/FALSE))))

;; Object[] values: STRING columns, and wide DECIMAL columns (BigInteger
;; unscaled values, spec/changes/decimal38.md).
(deftype StringVector [^objects values ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (aget values i)))

(deftype DictVector [^ints codes ^objects dict ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (aget dict (aget codes i)))))

(deftype RowView [^objects rows ^long col]
  ColumnVector
  (size [_] (alength rows))
  (isNull [_ i] (nil? (aget ^objects (aget rows i) col)))
  (valueAt [_ i] (aget ^objects (aget rows i) col)))

;; Zero-copy views over a little-endian buffer (memory-mapped PQCF chunks).

(deftype BufferLongVector [^ByteBuffer buf ^long base ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (.getLong buf (int (+ base (* 8 i)))))))

(deftype BufferIntVector [^ByteBuffer buf ^long base ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (long (.getInt buf (int (+ base (* 4 i))))))))

(deftype BufferDoubleVector [^ByteBuffer buf ^long base ^longs validity ^long n]
  ColumnVector
  (size [_] n)
  (isNull [_ i] (not (valid? validity i)))
  (valueAt [_ i] (when (valid? validity i) (.getDouble buf (int (+ base (* 8 i)))))))

(defn dictionary-encoded? [v] (instance? DictVector v))

;; ---------------------------------------------------------------------------
;; Construction

(defn- dictionary-encode
  "DictVector of a STRING Object array; with `max-distinct` gives up (nil)
  once more distinct values are seen."
  [^objects vals validity max-distinct]
  (let [n (alength vals)
        codes (int-array n)
        ids (HashMap.)
        limit (long (or max-distinct Long/MAX_VALUE))]
    (loop [i 0]
      (if (< i n)
        (let [s (aget vals i)]
          (if (nil? s)
            (recur (inc i))
            (let [code (or (.get ids s)
                           (let [c (int (.size ids))] (.put ids s c) c))]
              (aset codes i (int code))
              (if (> (.size ids) limit) nil (recur (inc i))))))
        (let [dict (object-array (.size ids))]
          (doseq [^java.util.Map$Entry e (.entrySet ids)]
            (aset dict (int (.getValue e)) (.getKey e)))
          (DictVector. codes dict validity n))))))

(defn from-objects
  "Builds a typed vector from an Object array of runtime values of type t.
  `dictionary`: true forces dictionary encoding of STRING columns, false
  disables it, :auto (default) applies it when at most half of the rows hold
  distinct values."
  ([t vals] (from-objects t vals :auto))
  ([t ^objects vals dictionary]
   (let [n (alength vals)
         validity (validity-of vals)]
     (case (t/kind t)
       :decimal
       (if (t/wide? t)
         (StringVector. (aclone vals) validity n)
         (let [a (long-array n)]
           (dotimes [i n] (when-some [x (aget vals i)] (aset a i (long x))))
           (LongVector. a validity n)))
       (:int64 :date :timestamp)
       (let [a (long-array n)]
         (dotimes [i n] (when-some [x (aget vals i)] (aset a i (long x))))
         (LongVector. a validity n))
       :float64
       (let [a (double-array n)]
         (dotimes [i n] (when-some [x (aget vals i)] (aset a i (double x))))
         (DoubleVector. a validity n))
       :boolean
       (let [bits (long-array (bitmap-words n))]
         (dotimes [i n] (when (true? (aget vals i)) (set-bit! bits i)))
         (BooleanVector. bits validity n))
       (:string :null)
       (or (case dictionary
             true (dictionary-encode vals validity nil)
             false nil
             (when (>= n 16) (dictionary-encode vals validity (quot n 2))))
           (StringVector. (aclone vals) validity n))))))

(defn to-objects
  "All values of a vector as an Object array."
  ^objects [^ColumnVector v]
  (let [n (.size v)
        out (object-array n)]
    (dotimes [i n] (aset out i (.valueAt v i)))
    out))

(defn null-count ^long [^ColumnVector v]
  (let [n (.size v)]
    (loop [i 0 c 0]
      (if (< i n) (recur (inc i) (if (.isNull v i) (inc c) c)) c))))
