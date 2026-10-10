(ns polyquery.values
  "Runtime value helpers: exact DECIMAL arithmetic on unscaled longs, the
  proleptic Gregorian calendar for DATE/TIMESTAMP, text parsing and
  formatting, CAST conversions and the total order of values
  (spec/data-types/types.md)."
  (:refer-clojure :exclude [parse-boolean])
  (:require [polyquery.errors :as err]
            [polyquery.types :as t]
            [polyquery.util.text :as text])
  (:import (java.math BigDecimal BigInteger RoundingMode)
           (java.util Comparator)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Decimal arithmetic. A DECIMAL value is a long `unscaled`; its scale comes
;; from the static type. Results must fit 18 digits.

(def ^"[J" pow10
  (long-array (take 19 (iterate #(* 10 (long %)) 1))))

(def ^:const max-unscaled 999999999999999999)

(defn overflow! [what]
  (err/fail! "NUMERIC_OVERFLOW" (str "numeric overflow in " what)))

(defn fits-precision?
  [^long v ^long p]
  (and (< v (aget pow10 p)) (> v (- (aget pow10 p)))))

(defn check-dec18
  "Returns v when it fits DECIMAL(18,_), else throws NUMERIC_OVERFLOW."
  ^long [^long v what]
  (if (and (<= v max-unscaled) (>= v (- max-unscaled)))
    v
    (overflow! what)))

(defn- big->dec18 ^long [^BigInteger b what]
  (if (< (.bitLength b) 63)
    (check-dec18 (.longValue b) what)
    (overflow! what)))

(defn- big-scaled ^BigInteger [^long v ^long k]
  (.multiply (BigInteger/valueOf v) (.pow BigInteger/TEN (int k))))

(defn dec-rescale-up
  "Exact v * 10^k as a BigInteger-or-long (returns a Number)."
  [^long v ^long k]
  (if (zero? k)
    v
    (try (Math/multiplyExact v (aget pow10 k))
         (catch ArithmeticException _ (big-scaled v k)))))

(defn- ->big ^BigInteger [x]
  (if (instance? BigInteger x) x (BigInteger/valueOf (long x))))

(defn dec-add
  "a (scale sa) + b (scale sb) at scale max(sa,sb); exact, 18-digit result."
  ^long [^long a ^long sa ^long b ^long sb]
  (let [s (max sa sb)
        x (dec-rescale-up a (- s sa))
        y (dec-rescale-up b (- s sb))]
    (if (and (instance? Long x) (instance? Long y))
      (try (check-dec18 (Math/addExact (long x) (long y)) "decimal addition")
           (catch ArithmeticException _ (overflow! "decimal addition")))
      (big->dec18 (.add (->big x) (->big y)) "decimal addition"))))

(defn dec-mul
  ^long [^long a ^long b]
  (try (check-dec18 (Math/multiplyExact a b) "decimal multiplication")
       (catch ArithmeticException _ (overflow! "decimal multiplication"))))

(defn dec-compare
  "Compares a (scale sa) with b (scale sb) by value."
  ^long [^long a ^long sa ^long b ^long sb]
  (if (= sa sb)
    (Long/compare a b)
    (let [s (max sa sb)
          x (dec-rescale-up a (- s sa))
          y (dec-rescale-up b (- s sb))]
      (if (and (instance? Long x) (instance? Long y))
        (Long/compare (long x) (long y))
        (long (.compareTo (->big x) (->big y)))))))

(defn dec->bigdec ^BigDecimal [^long v ^long s]
  (BigDecimal/valueOf v (int s)))

(defn dec->double ^double [^long v ^long s]
  (if (zero? s)
    (double v)
    (.doubleValue ^BigDecimal (dec->bigdec v s))))

(defn bigdec->unscaled
  "Rescales a BigDecimal to scale s (round half away from zero) and returns the
  unscaled long if it fits precision p; else throws NUMERIC_OVERFLOW."
  ^long [^BigDecimal bd ^long p ^long s]
  (let [u (.unscaledValue (.setScale bd (int s) RoundingMode/HALF_UP))]
    (if (and (< (.bitLength u) 63) (fits-precision? (.longValue u) p))
      (.longValue u)
      (overflow! (str "conversion to DECIMAL(" p "," s ")")))))

(defn dec-round-down
  "Reduces the scale of v from s to s2 (s2 < s), rounding half away from zero."
  ^long [^long v ^long s ^long s2]
  (let [k (- s s2)]
    (if (> k 18)
      0
      (let [d (aget pow10 k)
            q (quot v d)
            r (rem v d)]
        (if (>= (* 2 (Math/abs r)) d)
          (if (neg? v) (dec q) (inc q))
          q)))))

(defn dec-rescale
  "Rescales v from scale s to scale s2 (rounding half away from zero when
  reducing) and checks that the result fits precision p."
  ^long [^long v ^long s ^long p ^long s2]
  (let [r (cond
            (= s s2) v
            (< s s2) (let [x (dec-rescale-up v (- s2 s))]
                       (if (instance? Long x) (long x) (overflow! "decimal rescale")))
            :else (dec-round-down v s s2))]
    (if (fits-precision? r p) r (overflow! (str "conversion to DECIMAL(" p "," s2 ")")))))

(defn dec->string
  ^String [^long v ^long s]
  (if (zero? s)
    (Long/toString v)
    (let [neg (neg? v)
          digits (if (= v Long/MIN_VALUE)
                   (subs (Long/toString v) 1)
                   (Long/toString (Math/abs v)))
          digits (if (<= (count digits) s)
                   (str (apply str (repeat (- (inc s) (count digits)) \0)) digits)
                   digits)
          cut (- (count digits) s)]
      (str (when neg "-") (subs digits 0 cut) "." (subs digits cut)))))

;; ---------------------------------------------------------------------------
;; Calendar (proleptic Gregorian), days since 1970-01-01.

(defn days-from-civil
  ^long [^long y ^long m ^long d]
  (let [y (if (<= m 2) (dec y) y)
        era (quot (if (>= y 0) y (- y 399)) 400)
        yoe (- y (* era 400))
        mp (if (> m 2) (- m 3) (+ m 9))
        doy (+ (quot (+ (* 153 mp) 2) 5) (dec d))
        doe (+ (* yoe 365) (quot yoe 4) (- (quot yoe 100)) doy)]
    (+ (* era 146097) doe -719468)))

(defn civil-from-days
  "Returns [y m d] for a day number."
  [^long z]
  (let [z (+ z 719468)
        era (quot (if (>= z 0) z (- z 146096)) 146097)
        doe (- z (* era 146097))
        yoe (quot (- doe (quot doe 1460) (- (quot doe 36524)) (quot doe 146096)) 365)
        y (+ yoe (* era 400))
        doy (- doe (- (+ (* 365 yoe) (quot yoe 4)) (quot yoe 100)))
        mp (quot (+ (* 5 doy) 2) 153)
        d (inc (- doy (quot (+ (* 153 mp) 2) 5)))
        m (if (< mp 10) (+ mp 3) (- mp 9))]
    [(if (<= m 2) (inc y) y) m d]))

(defn leap-year? [^long y]
  (and (zero? (rem y 4)) (or (pos? (rem y 100)) (zero? (rem y 400)))))

(defn days-in-month ^long [^long y ^long m]
  (case (int m)
    (1 3 5 7 8 10 12) 31
    (4 6 9 11) 30
    2 (if (leap-year? y) 29 28)))

(def ^:const micros-per-day 86400000000)

(defn- digit-at ^long [^String s ^long i]
  (let [c (.charAt s i)]
    (if (and (>= (int c) 48) (<= (int c) 57)) (- (int c) 48) -1)))

(defn- digits-at
  "Parses n digits at position i; returns -1 if any is not a digit."
  ^long [^String s ^long i ^long n]
  (loop [k 0 acc 0]
    (if (= k n)
      acc
      (let [d (digit-at s (+ i k))]
        (if (neg? d) -1 (recur (inc k) (+ (* acc 10) d)))))))

(defn- parse-date-prefix
  "Parses YYYY-MM-DD at the start of s; returns the day number or nil."
  [^String s]
  (when (and (>= (.length s) 10)
             (= (.charAt s 4) \-) (= (.charAt s 7) \-))
    (let [y (digits-at s 0 4) m (digits-at s 5 2) d (digits-at s 8 2)]
      (when (and (>= y 1) (<= 1 m 12) (>= d 1) (<= d (days-in-month y m)))
        (days-from-civil y m d)))))

(defn parse-date
  "Parses exactly YYYY-MM-DD (valid calendar date); nil if invalid."
  [^String s]
  (when (= (.length s) 10) (parse-date-prefix s)))

(defn parse-timestamp
  "Parses YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}]; with allow-date? also a bare date
  (midnight). Returns microseconds or nil."
  ([s] (parse-timestamp s false))
  ([^String s allow-date?]
   (let [n (.length s)]
     (if (= n 10)
       (when allow-date?
         (when-let [d (parse-date-prefix s)] (* (long d) micros-per-day)))
       (when (and (>= n 19)
                  (let [c (.charAt s 10)] (or (= c \space) (= c \T)))
                  (= (.charAt s 13) \:) (= (.charAt s 16) \:))
         (when-let [d (parse-date-prefix s)]
           (let [hh (digits-at s 11 2) mi (digits-at s 14 2) ss (digits-at s 17 2)
                 frac (cond
                        (= n 19) 0
                        (and (= (.charAt s 19) \.) (<= 21 n 26))
                        (let [f (digits-at s 20 (- n 20))]
                          (when (>= f 0) (* f (aget pow10 (- 26 n)))))
                        :else nil)]
             (when (and frac (<= 0 hh 23) (<= 0 mi 59) (<= 0 ss 59))
               (+ (* (long d) micros-per-day)
                  (* (+ (* hh 3600) (* mi 60) ss) 1000000)
                  (long frac))))))))))

(defn- pad ^String [^long v ^long width]
  (let [s (Long/toString v)]
    (if (< (count s) width)
      (str (apply str (repeat (- width (count s)) \0)) s)
      s)))

(defn format-date ^String [^long days]
  (let [[y m d] (civil-from-days days)]
    (str (pad y 4) "-" (pad m 2) "-" (pad d 2))))

(defn timestamp-date ^long [^long micros]
  (Math/floorDiv micros (long micros-per-day)))

(defn format-timestamp ^String [^long micros]
  (let [days (timestamp-date micros)
        tod (- micros (* days micros-per-day))
        secs (quot tod 1000000)
        frac (rem tod 1000000)]
    (str (format-date days) " "
         (pad (quot secs 3600) 2) ":" (pad (rem (quot secs 60) 60) 2) ":" (pad (rem secs 60) 2)
         (when (pos? frac) (str "." (pad frac 6))))))

;; ---------------------------------------------------------------------------
;; Numeric text parsing (ingestion.md §1.1, types.md §8)

(def int-pattern #"[+-]?[0-9]+")
(def float-pattern #"[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?")
(def decimal-pattern #"[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)")

(defn int-text? [^String s] (boolean (re-matches int-pattern s)))

(defn parse-int64
  "Parses integer text: Long, :overflow if out of range, nil if malformed."
  [^String s]
  (when (re-matches int-pattern s)
    (try (Long/parseLong s)
         (catch NumberFormatException _ :overflow))))

(defn parse-float64
  "Parses float text: Double, :overflow if not finite, nil if malformed."
  [^String s]
  (when (re-matches float-pattern s)
    (let [d (Double/parseDouble s)]
      (if (Double/isInfinite d) :overflow d))))

(defn parse-boolean
  [^String s]
  (cond (.equalsIgnoreCase "true" s) true
        (.equalsIgnoreCase "false" s) false
        :else nil))

(defn parse-decimal-exact
  "Ingestion rule: at most s fractional digits, value fits p. Returns the
  unscaled long, or nil if not acceptable."
  [^String text ^long p ^long s]
  (when (re-matches decimal-pattern text)
    (let [neg (.startsWith text "-")
          body (if (or neg (.startsWith text "+")) (subs text 1) text)
          dot (.indexOf body ".")
          ip (if (neg? dot) body (subs body 0 dot))
          fp (if (neg? dot) "" (subs body (inc dot)))
          ip (.replaceFirst ^String ip "^0+" "")]
      (when (and (<= (count fp) s) (<= (+ (count ip) s) p))
        (let [digits (str ip fp (apply str (repeat (- s (count fp)) \0)))
              u (if (empty? digits) 0 (Long/parseLong digits))]
          (if neg (- u) u))))))

(defn parse-decimal-rounding
  "CAST rule: rounds half away from zero to s digits; returns the unscaled
  long, throws NUMERIC_OVERFLOW if it does not fit p, nil if malformed."
  [^String text ^long p ^long s]
  (when (re-matches decimal-pattern text)
    (bigdec->unscaled (BigDecimal. text) p s)))

;; ---------------------------------------------------------------------------
;; Float helpers

(defn check-finite ^double [^double d what]
  (if (or (Double/isInfinite d) (Double/isNaN d))
    (overflow! what)
    d))

(defn float->string ^String [^double d]
  (if (== d 0.0) "0.0" (Double/toString d)))

;; ---------------------------------------------------------------------------
;; Output serialization (types.md §9)

(defn value->json
  "Converts a runtime value of type t into its JSON representation."
  [t v]
  (when (some? v)
    (case (t/kind t)
      :decimal (dec->string (long v) (t/scale t))
      :date (format-date (long v))
      :timestamp (format-timestamp (long v))
      :float64 (let [d (double v)] (if (== d 0.0) 0.0 v))
      v)))

(defn value->string
  "STRING cast text of a value (types.md §8)."
  ^String [t v]
  (case (t/kind t)
    :boolean (if v "true" "false")
    :int64 (Long/toString (long v))
    :float64 (float->string (double v))
    :decimal (dec->string (long v) (t/scale t))
    :string v
    :date (format-date (long v))
    :timestamp (format-timestamp (long v))))

;; ---------------------------------------------------------------------------
;; Ordering (types.md §5, §7)

(defn value-comparator
  "A Comparator over non-null values of type t."
  ^Comparator [t]
  (case (t/kind t)
    :boolean (reify Comparator
               (compare [_ a b] (Boolean/compare (boolean a) (boolean b))))
    (:int64 :decimal :date :timestamp)
    (reify Comparator
      (compare [_ a b] (Long/compare (long a) (long b))))
    :float64 (reify Comparator
               (compare [_ a b]
                 (let [x (double a) y (double b)]
                   (cond (< x y) -1 (> x y) 1 :else 0))))
    :string (reify Comparator
              (compare [_ a b] (text/compare-code-points a b)))
    :null (reify Comparator (compare [_ _ _] 0))))

(defn normalize-key
  "Normalizes a value for hashing/equality (DISTINCT): -0.0 equals 0.0."
  [v]
  (if (and (instance? Double v) (== 0.0 (double v))) 0.0 v))

(defn ->double-fn
  "Function converting a non-null value of numeric type t to double."
  [t]
  (case (t/kind t)
    :int64 (fn ^double [x] (double (long x)))
    :float64 (fn ^double [x] (double x))
    :decimal (let [s (t/scale t)] (fn ^double [x] (dec->double (long x) s)))
    :null (fn ^double [_] 0.0)))

(defn comparator-fn
  "Returns (fn [a b]) → negative/zero/positive for non-null operands of
  types lt and rt compared in their comparison type cmp-type (§2, §5)."
  [cmp-type lt rt]
  (case (t/kind cmp-type)
    :int64 (fn [a b] (Long/compare (long a) (long b)))
    :float64 (let [dl (->double-fn lt) dr (->double-fn rt)]
               (fn [a b] (let [x (double (dl a)) y (double (dr b))]
                           (cond (< x y) -1 (> x y) 1 :else 0))))
    :decimal (let [sl (t/scale lt) sr (t/scale rt)]
               (fn [a b] (dec-compare (long a) sl (long b) sr)))
    :timestamp (let [conv (fn [t] (if (= t :date)
                                    (fn ^long [x] (* (long x) micros-per-day))
                                    (fn ^long [x] (long x))))
                     cl (conv lt) cr (conv rt)]
                 (fn [a b] (Long/compare (long (cl a)) (long (cr b)))))
    (let [^Comparator cmp (value-comparator cmp-type)]
      (fn [a b] (.compare cmp a b)))))

(defn key-fn
  "Returns a function mapping a non-null value of type `from` to a hashable
  key such that values equal in comparison type cmp-type (§5) have equal keys
  (hash joins, IN subqueries)."
  [from cmp-type]
  (case (t/kind cmp-type)
    :float64 (let [d (->double-fn from)]
               (fn [x] (let [v (double (d x))] (if (== v 0.0) 0.0 v))))
    :decimal (let [k (- (t/scale cmp-type) (t/scale from))]
               (fn [x] (dec-rescale-up (long x) k)))
    :timestamp (if (= from :date)
                 (fn [x] (* (long x) micros-per-day))
                 identity)
    identity))

;; ---------------------------------------------------------------------------
;; CAST (types.md §8)

(defn- conversion-error! [v target]
  (err/fail! "CONVERSION_ERROR" (str "cannot convert '" v "' to " (t/type-name target))))

(defn castable?
  [from to]
  (let [f (t/kind from) k (t/kind to)]
    (or (= f :null)
        (= f k)
        (= f :string)
        (= k :string)
        (case f
          :boolean (= k :int64)
          :int64 (contains? #{:boolean :decimal :float64} k)
          :decimal (contains? #{:int64 :float64} k)
          :float64 (contains? #{:int64 :decimal} k)
          :date (= k :timestamp)
          :timestamp (= k :date)
          false))))

(defn- float->int64 ^long [^double d]
  (if (or (>= d 9.223372036854775807E18) (< d -9.223372036854775808E18))
    (overflow! "conversion to INT64")
    (long d)))

(defn cast-fn
  "Returns a function converting a non-null value of type `from` to type `to`.
  Assumes (castable? from to)."
  [from to]
  (let [f (t/kind from) k (t/kind to)]
    (cond
      (= from to) identity
      (= f :null) (constantly nil)
      (= k :string) (fn [v] (value->string from v))
      :else
      (case f
        :boolean (fn [v] (if v 1 0))
        :int64 (case k
                 :boolean (fn [v] (not (zero? (long v))))
                 :float64 (fn [v] (double (long v)))
                 :decimal (let [p (t/precision to) s (t/scale to)]
                            (fn [v]
                              (let [x (dec-rescale-up (long v) s)]
                                (if (and (instance? Long x) (fits-precision? (long x) p))
                                  x
                                  (overflow! (str "conversion to " (t/type-name to))))))))
        :decimal (let [s (t/scale from)]
                   (case k
                     :int64 (fn [v] (quot (long v) (aget pow10 s)))
                     :float64 (fn [v] (dec->double (long v) s))
                     :decimal (let [p (t/precision to) s2 (t/scale to)]
                                (fn [v] (dec-rescale (long v) s p s2)))))
        :float64 (case k
                   :int64 (fn [v] (float->int64 (double v)))
                   :decimal (let [p (t/precision to) s (t/scale to)]
                              (fn [v] (bigdec->unscaled (BigDecimal. (double v)) p s))))
        :date (fn [v] (* (long v) micros-per-day))
        :timestamp (fn [v] (timestamp-date (long v)))
        :string
        (case k
          :boolean (fn [v] (let [r (parse-boolean (text/trim-blank v))]
                             (if (nil? r) (conversion-error! v to) r)))
          :int64 (fn [v] (let [r (parse-int64 (text/trim-blank v))]
                           (cond (nil? r) (conversion-error! v to)
                                 (= r :overflow) (overflow! "conversion to INT64")
                                 :else r)))
          :float64 (fn [v] (let [r (parse-float64 (text/trim-blank v))]
                             (cond (nil? r) (conversion-error! v to)
                                   (= r :overflow) (overflow! "conversion to FLOAT64")
                                   :else r)))
          :decimal (let [p (t/precision to) s (t/scale to)]
                     (fn [v] (let [r (parse-decimal-rounding (text/trim-blank v) p s)]
                               (if (nil? r) (conversion-error! v to) r))))
          :date (fn [v] (or (parse-date (text/trim-blank v)) (conversion-error! v to)))
          :timestamp (fn [v] (or (parse-timestamp (text/trim-blank v))
                                 (conversion-error! v to))))))))
