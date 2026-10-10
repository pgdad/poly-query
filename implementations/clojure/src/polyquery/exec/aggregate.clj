(ns polyquery.exec.aggregate
  "Aggregate accumulators (spec/sql/functions.md §2). Integer and DECIMAL
  sums are exact: they accumulate in a long and switch to BigInteger on
  overflow, so only the final result is range-checked."
  (:require [polyquery.errors :as err]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.math BigDecimal BigInteger MathContext)
           (java.util Comparator HashSet)))

(set! *warn-on-reflection* true)

(definterface Accumulator
  (add [x] "Feeds one (possibly NULL) input value.")
  (result [] "Returns the aggregate value.")
  (state [] "The partial state, as consumed by merge.")
  (merge [other] "Adds the partial state of another accumulator of the same
  kind (parallel aggregation)."))

(deftype CountStar [^:unsynchronized-mutable ^long n]
  Accumulator
  (add [_ _] (set! n (inc n)) nil)
  (result [_] n)
  (state [_] n)
  (merge [_ other] (set! n (+ n (long (.state ^Accumulator other)))) nil))

(deftype CountValues [^:unsynchronized-mutable ^long n]
  Accumulator
  (add [_ x] (when (some? x) (set! n (inc n))) nil)
  (result [_] n)
  (state [_] n)
  (merge [_ other] (set! n (+ n (long (.state ^Accumulator other)))) nil))

(definterface Counted
  (^long valueCount []))

(deftype ExactSum [^:unsynchronized-mutable ^long sum
                   ^:unsynchronized-mutable ^BigInteger big
                   ^:unsynchronized-mutable ^long n]
  Accumulator
  (add [_ x]
    (when (some? x)
      (set! n (inc n))
      (if big
        (set! big (.add big (BigInteger/valueOf (long x))))
        (let [s (unchecked-add sum (long x))]
          ;; overflow iff both operands have the same sign and the result's differs
          (if (neg? (bit-and (bit-xor sum s) (bit-xor (long x) s)))
            (set! big (.add (BigInteger/valueOf sum) (BigInteger/valueOf (long x))))
            (set! sum s)))))
    nil)
  (result [_]
    (when (pos? n) (or big sum)))
  (state [_] (object-array [(or big sum) n]))
  (merge [_ other]
    (let [^objects st (.state ^Accumulator other)
          x (aget st 0)
          m (long (aget st 1))]
      (when (pos? m)
        (set! n (+ n m))
        (if (or big (instance? BigInteger x))
          (let [^BigInteger acc (if big big (BigInteger/valueOf sum))
                ^BigInteger y (if (instance? BigInteger x) x (BigInteger/valueOf (long x)))]
            (set! big (.add acc y)))
          (let [y (long x)
                s (unchecked-add sum y)]
            (if (neg? (bit-and (bit-xor sum s) (bit-xor y s)))
              (set! big (.add (BigInteger/valueOf sum) (BigInteger/valueOf y)))
              (set! sum s))))))
    nil)
  Counted
  (valueCount [_] n))

(defn- exact-sum ^ExactSum [] (ExactSum. 0 nil 0))

(defn- sum-count ^long [^Counted acc] (.valueCount acc))

(deftype FloatSum [^:unsynchronized-mutable ^double sum ^:unsynchronized-mutable ^long n avg?]
  Accumulator
  (add [_ x] (when (some? x) (set! sum (+ sum (double x))) (set! n (inc n))) nil)
  (result [_]
    (when (pos? n)
      (let [r (if avg? (/ sum n) sum)]
        (if (or (Double/isInfinite r) (Double/isNaN r))
          (err/fail! "NUMERIC_OVERFLOW" "floating point overflow in SUM")
          r))))
  (state [_] (object-array [sum n]))
  (merge [_ other]
    (let [^objects st (.state ^Accumulator other)]
      (set! sum (+ sum (double (aget st 0))))
      (set! n (+ n (long (aget st 1)))))
    nil))

(deftype Extreme [^Comparator cmp ^long sign ^:unsynchronized-mutable best]
  Accumulator
  (add [_ x]
    (when (and (some? x) (or (nil? best) (neg? (* sign (.compare cmp x best)))))
      (set! best x))
    nil)
  (result [_] best)
  (state [_] best)
  (merge [this other] (.add this (.state ^Accumulator other))))

(deftype Wrapped [^Accumulator inner finish]
  Accumulator
  (add [_ x] (.add inner x))
  (result [_] (finish inner))
  (state [_] inner)
  (merge [_ other] (.merge inner (.state ^Accumulator other))))

(deftype DistinctValues [^HashSet seen make-inner]
  Accumulator
  (add [_ x] (when (some? x) (.add seen (v/normalize-key x))) nil)
  (result [_]
    (let [^Accumulator inner (make-inner)]
      (doseq [x seen] (.add inner x))
      (.result inner)))
  (state [_] seen)
  (merge [_ other] (.addAll seen ^HashSet (.state ^Accumulator other)) nil))

(defn int-sum-result
  "Final INT64 SUM of an exact sum (Long or BigInteger; nil for no values)."
  [x]
  (cond
    (nil? x) nil
    (instance? BigInteger x) (if (< (.bitLength ^BigInteger x) 64)
                               (.longValue ^BigInteger x)
                               (err/fail! "NUMERIC_OVERFLOW" "SUM overflows INT64"))
    :else x))

(defn dec-sum-result
  "Final DECIMAL SUM of an exact unscaled sum (nil for no values)."
  [x]
  (when (some? x)
    (let [l (int-sum-result x)]
      (v/check-dec18 (long l) "SUM"))))

(defn exact-avg-result
  "AVG of INT64/DECIMAL values from their exact unscaled sum s (Long or
  BigInteger, nil for no values) and count."
  [s cnt scale]
  (when (some? s)
    (let [bd (BigDecimal. (if (instance? BigInteger s) ^BigInteger s (BigInteger/valueOf (long s)))
                          (int scale))]
      (.doubleValue (.divide bd (BigDecimal/valueOf (long cnt)) MathContext/DECIMAL128)))))

(defn- exact-avg [^ExactSum acc ^long scale]
  (exact-avg-result (.result acc) (sum-count acc) scale))

(defn accumulator-factory
  "Returns a no-arg function creating a fresh accumulator for agg spec."
  [{f :fn distinct? :distinct? arg :arg}]
  (let [at (:type arg)
        base (case f
               :count-star #(CountStar. 0)
               :count #(CountValues. 0)
               :sum (case (t/kind at)
                      :int64 #(Wrapped. (exact-sum) (fn [^Accumulator a] (int-sum-result (.result a))))
                      :decimal #(Wrapped. (exact-sum) (fn [^Accumulator a] (dec-sum-result (.result a))))
                      :float64 #(FloatSum. 0.0 0 false)
                      :null #(CountStar. 0))
               :avg (case (t/kind at)
                      (:int64 :decimal) (let [s (t/scale at)]
                                          #(Wrapped. (exact-sum) (fn [a] (exact-avg a s))))
                      :float64 #(FloatSum. 0.0 0 true)
                      :null #(CountStar. 0))
               (:min :max) (let [cmp (v/value-comparator at)
                                 sign (if (= f :min) 1 -1)]
                             #(Extreme. cmp sign nil)))
        base (if (and (#{:sum :avg} f) (= :null at))
               ;; SUM/AVG over the NULL type: always NULL
               #(Wrapped. (CountStar. 0) (constantly nil))
               base)]
    (if (and distinct? (not= f :count-star))
      #(DistinctValues. (HashSet.) base)
      base)))
