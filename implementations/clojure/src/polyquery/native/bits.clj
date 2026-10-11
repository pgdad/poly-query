(ns polyquery.native.bits
  "Conversions between the vectorized engine's batch representation
  (boolean[] null masks, int[] selection vectors; polyquery.exec.batch) and
  the bitmaps of the native kernel ABI: long[] words, row i = bit i%64 of
  word i/64 (the LSB-first byte bitmap on a little-endian machine).

  Kernels work on a batch's positions [0, span), span = last selected
  position + 1. Values at unselected positions are meaningless but
  harmless (no kernel can fail on them); results are restricted to the
  selection by AND-ing with the selection bitmap. Bits at or above span in
  the last word are don't-care and are masked off by `bitmap->sel`."
  (:require [polyquery.exec.batch :as b]))

(set! *warn-on-reflection* true)

(def ^:const words
  "Words of a bitmap covering one batch."
  (quot (+ b/capacity 63) 64))

(defn bitmap
  "A fresh bitmap for one batch."
  ^longs []
  (long-array words))

(defn nwords
  "Words covering positions [0, span)."
  ^long [^long span]
  (unsigned-bit-shift-right (+ span 63) 6))

(defn span
  "Positions a kernel must cover for selection (sel, n)."
  ^long [^ints sel ^long n]
  (cond
    (identical? sel b/identity-sel) n
    (zero? n) 0
    :else (inc (aget sel (dec n)))))

(defn identity-sel? [^ints sel] (identical? sel b/identity-sel))

(defn fill!
  "Sets every bit of the first (nwords span) words to `on?`."
  ^longs [^longs out ^long span on?]
  (java.util.Arrays/fill out 0 (int (nwords span)) (if on? -1 0))
  out)

(defn valid-bits!
  "Bitmap of the non-NULL positions [0, span) of a null mask."
  ^longs [^booleans nulls ^long span ^longs out]
  (dotimes [w (nwords span)]
    (let [base (* 64 w)
          end (min 64 (- span base))]
      (aset out w (long (loop [j 0 acc -1]
                          (if (< j end)
                            (recur (inc j) (if (aget nulls (+ base j))
                                             (bit-and-not acc (bit-shift-left 1 j))
                                             acc))
                            acc))))))
  out)

(defn true-bits!
  "Bitmap of the positions [0, span) where boolean array v is true (or
  false, with negate?)."
  ^longs [^booleans v ^long span negate? ^longs out]
  (let [neg (boolean negate?)]
    (dotimes [w (nwords span)]
      (let [base (* 64 w)
            end (min 64 (- span base))]
        (aset out w (long (loop [j 0 acc 0]
                            (if (< j end)
                              (recur (inc j) (if (not= neg (aget v (+ base j)))
                                               (bit-or acc (bit-shift-left 1 j))
                                               acc))
                              acc)))))))
  out)

(defn sel-bits!
  "Bitmap of the selected positions of (sel, n)."
  ^longs [^ints sel ^long n ^longs out]
  (if (identity-sel? sel)
    (fill! out n true)
    (do (java.util.Arrays/fill out 0)
        (dotimes [k n]
          (let [i (aget sel k)
                w (unsigned-bit-shift-right i 6)]
            (aset out w (bit-or (aget out w) (bit-shift-left 1 (bit-and i 63))))))
        out)))

(defn valid-sel-bits!
  "Bitmap of the selected positions of (sel, n) that are not NULL in mask
  `nulls` (nil = none is NULL); nil when that is every position of the
  identity selection (a NULL validity pointer)."
  [^booleans nulls ^ints sel ^long n ^longs out]
  (cond
    (and (nil? nulls) (identity-sel? sel)) nil
    (identity-sel? sel) (valid-bits! nulls n out)
    :else (do (java.util.Arrays/fill out 0)
              (dotimes [k n]
                (let [i (aget sel k)]
                  (when-not (and nulls (aget nulls i))
                    (let [w (unsigned-bit-shift-right i 6)]
                      (aset out w (bit-or (aget out w) (bit-shift-left 1 (bit-and i 63))))))))
              out)))

(defn bit-set?
  [^longs bits ^long i]
  (not (zero? (bit-and (aget bits (unsigned-bit-shift-right i 6)) (bit-shift-left 1 (bit-and i 63))))))

(defn- last-mask ^long [^long span]
  (let [r (bit-and span 63)]
    (if (zero? r) -1 (dec (bit-shift-left 1 r)))))

(defn bitmap->sel
  "[sel n] of the set bits among positions [0, span) of a bitmap; the
  identity selection when that is every position 0..span-1 (span = n)."
  [^longs bits ^long span identity-ok?]
  (let [nw (nwords span)
        lm (last-mask span)
        word (fn ^long [^long w] (if (= w (dec nw)) (bit-and (aget bits w) lm) (aget bits w)))
        cnt (loop [w 0 c 0]
              (if (< w nw) (recur (inc w) (+ c (Long/bitCount (word w)))) c))]
    (if (and identity-ok? (= cnt span))
      [b/identity-sel cnt]
      (let [out (int-array cnt)]
        (loop [w 0 c 0]
          (when (< w nw)
            (let [base (* 64 w)
                  c (long (loop [x (word w) c c]
                            (if (zero? x)
                              c
                              (do (aset out c (int (+ base (Long/numberOfTrailingZeros x))))
                                  (recur (bit-and x (unchecked-dec x)) (inc c))))))]
              (recur (inc w) c))))
        [out cnt]))))
