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
;; Decimal arithmetic. A DECIMAL value is its unscaled integer; the scale
;; comes from the static type. Narrow decimals (p <= 18) are Longs, computed
;; with long fast paths and BigInteger fallbacks wherever an intermediate may
;; exceed 64 bits; their results must fit 18 digits. Wide decimals (p > 18,
;; spec/changes/decimal38.md) are BigIntegers; their results must fit 38
;; digits. Only final results are range-checked.

(def ^"[J" pow10
  (long-array (take 19 (iterate #(* 10 (long %)) 1))))

(def ^:const max-unscaled 999999999999999999)

(def ^:private ^"[Ljava.math.BigInteger;" big-pow10s
  ;; up to 10^77: products of two wide operands have at most 76 digits
  (into-array BigInteger (take 78 (iterate #(.multiply ^BigInteger % BigInteger/TEN) BigInteger/ONE))))

(defn big-pow10 ^BigInteger [k] (aget big-pow10s (int k)))

(defn overflow! [what]
  (err/fail! "NUMERIC_OVERFLOW" (str "numeric overflow in " what)))

(defn fits-precision?
  [^long v ^long p]
  (and (< v (aget pow10 p)) (> v (- (aget pow10 p)))))

(defn ->big
  "A Long or BigInteger unscaled value as a BigInteger."
  ^BigInteger [x]
  (if (instance? BigInteger x) x (BigInteger/valueOf (long x))))

(defn big-fits?
  "True when |u| < 10^p."
  [^BigInteger u ^long p]
  (neg? (.compareTo (.abs u) (big-pow10 p))))

(defn dec-value
  "The runtime value of unscaled u (assumed to fit p) for a decimal of
  precision p: a Long when narrow, the BigInteger when wide."
  [^BigInteger u ^long p]
  (if (<= p (long t/narrow-precision)) (.longValue u) u))

(defn check-dec18
  "Returns v when it fits DECIMAL(18,_), else throws NUMERIC_OVERFLOW."
  ^long [^long v what]
  (if (and (<= v max-unscaled) (>= v (- max-unscaled)))
    v
    (overflow! what)))

(defn check-dec38
  "Returns u when it fits DECIMAL(38,_), else throws NUMERIC_OVERFLOW."
  ^BigInteger [^BigInteger u what]
  (if (big-fits? u t/max-decimal-precision) u (overflow! what)))

(defn- big->dec18 ^long [^BigInteger b what]
  (if (< (.bitLength b) 63)
    (check-dec18 (.longValue b) what)
    (overflow! what)))

(defn- big-scaled ^BigInteger [v k]
  (.multiply (BigInteger/valueOf v) (big-pow10 k)))

(defn dec-rescale-up
  "Exact v * 10^k as a Long when it fits, else a BigInteger (returns a
  Number)."
  [^long v ^long k]
  (if (zero? k)
    v
    (if (<= k 18)
      (try (Math/multiplyExact v (aget pow10 k))
           (catch ArithmeticException _ (big-scaled v k)))
      (big-scaled v k))))

(defn big-rescale-up
  "Exact x * 10^k of a Long or BigInteger x, as a BigInteger."
  ^BigInteger [x k]
  (let [k (long k)]
    (if (zero? k) (->big x) (.multiply (->big x) (big-pow10 k)))))

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

(defn wide-add
  "a (scale sa) + b (scale sb) at scale max(sa,sb) for Long/BigInteger
  operands; exact, 38-digit BigInteger result."
  ^BigInteger [a ^long sa b ^long sb]
  (let [s (max sa sb)]
    (check-dec38 (.add (big-rescale-up a (- s sa)) (big-rescale-up b (- s sb))) "decimal addition")))

(defn wide-sub
  "a (scale sa) - b (scale sb), as wide-add."
  ^BigInteger [a ^long sa b ^long sb]
  (let [s (max sa sb)]
    (check-dec38 (.subtract (big-rescale-up a (- s sa)) (big-rescale-up b (- s sb)))
                 "decimal subtraction")))

(defn wide-mul
  "Exact product of two Long/BigInteger unscaled values (up to 76 digits
  before the check), 38-digit BigInteger result."
  ^BigInteger [a b]
  (check-dec38 (.multiply (->big a) (->big b)) "decimal multiplication"))

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

(defn dec-compare-any
  "Exact comparison of a (scale sa) with b (scale sb), each a Long or a
  BigInteger unscaled value."
  ^long [a ^long sa b ^long sb]
  (if (and (instance? Long a) (instance? Long b))
    (dec-compare (long a) sa (long b) sb)
    (let [s (max sa sb)]
      (long (.compareTo (big-rescale-up a (- s sa)) (big-rescale-up b (- s sb)))))))

(defn dec->bigdec ^BigDecimal [v s]
  (if (instance? BigInteger v)
    (BigDecimal. ^BigInteger v (int s))
    (BigDecimal/valueOf (long v) (int s))))

(defn dec->double
  "The FLOAT64 nearest to the decimal (Long or BigInteger unscaled v, scale s)."
  ^double [v ^long s]
  (if (and (zero? s) (instance? Long v))
    (double (long v))
    (.doubleValue ^BigDecimal (dec->bigdec v s))))

(defn bigdec->unscaled
  "Rescales a BigDecimal to scale s (round half away from zero) and returns
  the unscaled value (Long for p <= 18, BigInteger above) if it fits
  precision p; else throws NUMERIC_OVERFLOW."
  [^BigDecimal bd ^long p ^long s]
  (let [u (.unscaledValue (.setScale bd (int s) RoundingMode/HALF_UP))]
    (if (big-fits? u p)
      (dec-value u p)
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
  reducing) and checks that the result fits precision p (narrow v and p)."
  ^long [^long v ^long s ^long p ^long s2]
  (let [r (cond
            (= s s2) v
            (< s s2) (let [x (dec-rescale-up v (- s2 s))]
                       (if (instance? Long x) (long x) (overflow! "decimal rescale")))
            :else (dec-round-down v s s2))]
    (if (fits-precision? r p) r (overflow! (str "conversion to DECIMAL(" p "," s2 ")")))))

(defn dec-convert
  "Converts a decimal value v of scale s to DECIMAL(p,s2) (round half away
  from zero, NUMERIC_OVERFLOW when it does not fit); either side may be
  narrow or wide."
  [v ^long s ^long p ^long s2]
  (if (and (instance? Long v) (<= p (long t/narrow-precision)))
    (dec-rescale (long v) s p s2)
    (bigdec->unscaled (dec->bigdec v s) p s2)))

(defn dec-negate [x]
  (if (instance? BigInteger x) (.negate ^BigInteger x) (- (long x))))

(defn- pad ^String [^long v ^long width]
  (let [s (Long/toString v)]
    (if (< (count s) width)
      (str (apply str (repeat (- width (count s)) \0)) s)
      s)))

(defn- append-digits!
  "Appends v (0 <= v < 10^width) zero-padded to width digits."
  [^StringBuilder sb ^long v ^long width]
  (loop [k (dec width)]
    (when (and (pos? k) (< v (aget pow10 k)))
      (.append sb \0)
      (recur (dec k))))
  (.append sb v))

(defn- dec->string*
  ^String [v ^long s]
  (let [big? (instance? BigInteger v)]
    (if (zero? s)
      (if big? (.toString ^BigInteger v) (Long/toString (long v)))
      (let [neg (if big? (neg? (.signum ^BigInteger v)) (neg? (long v)))
            digits (cond
                     big? (.toString (.abs ^BigInteger v))
                     (= (long v) Long/MIN_VALUE) (subs (Long/toString (long v)) 1)
                     :else (Long/toString (Math/abs (long v))))
            digits (if (<= (count digits) s)
                     (str (apply str (repeat (- (inc s) (count digits)) \0)) digits)
                     digits)
            cut (- (count digits) s)]
        (str (when neg "-") (subs digits 0 cut) "." (subs digits cut))))))

(defn append-decimal!
  "Appends the canonical text of a decimal (see dec->string) to sb."
  ^StringBuilder [^StringBuilder sb v ^long s]
  (if (or (instance? BigInteger v) (= (long v) Long/MIN_VALUE) (> s 18))
    (.append sb (dec->string* v s))
    (let [x (long v)]
      (if (zero? s)
        (.append sb x)
        (let [p (aget pow10 s)
              a (Math/abs x)]
          (when (neg? x) (.append sb \-))
          (.append sb (quot a p))
          (.append sb \.)
          (append-digits! sb (rem a p) s))))))

(defn dec->string
  "Canonical text of a decimal (Long or BigInteger unscaled v, scale s)."
  ^String [v ^long s]
  (.toString (append-decimal! (StringBuilder.) v s)))

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

(defmacro ^:private let-civil
  "Binds y m d to the calendar fields of day number z (primitive longs)."
  [[y m d] z & body]
  `(let [z# (+ (long ~z) 719468)
         era# (quot (if (>= z# 0) z# (- z# 146096)) 146097)
         doe# (- z# (* era# 146097))
         yoe# (quot (- doe# (quot doe# 1460) (- (quot doe# 36524)) (quot doe# 146096)) 365)
         y# (+ yoe# (* era# 400))
         doy# (- doe# (- (+ (* 365 yoe#) (quot yoe# 4)) (quot yoe# 100)))
         mp# (quot (+ (* 5 doy#) 2) 153)
         ~d (inc (- doy# (quot (+ (* 153 mp#) 2) 5)))
         ~m (if (< mp# 10) (+ mp# 3) (- mp# 9))
         ~y (if (<= ~m 2) (inc y#) y#)]
     ~@body))

(defn civil-from-days
  "Returns [y m d] for a day number."
  [^long z]
  (let-civil [y m d] z [y m d]))

(defn year-of-days ^long [^long z] (let-civil [y _m _d] z y))
(defn month-of-days ^long [^long z] (let-civil [_y m _d] z m))
(defn day-of-days ^long [^long z] (let-civil [_y _m d] z d))

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

(defn append-date!
  "Appends the text of a DATE (days since the epoch) to sb."
  ^StringBuilder [^StringBuilder sb ^long days]
  (let-civil [y m d] days
    (if (<= 0 y 9999)
      (append-digits! sb y 4)
      (.append sb (pad y 4)))
    (.append sb \-)
    (append-digits! sb m 2)
    (.append sb \-)
    (append-digits! sb d 2))
  sb)

(defn format-date ^String [^long days]
  (.toString (append-date! (StringBuilder. 10) days)))

(defn timestamp-date ^long [^long micros]
  (Math/floorDiv micros (long micros-per-day)))

(defn append-timestamp!
  "Appends the text of a TIMESTAMP (microseconds since the epoch) to sb."
  ^StringBuilder [^StringBuilder sb ^long micros]
  (let [days (timestamp-date micros)
        tod (- micros (* days micros-per-day))
        secs (quot tod 1000000)
        frac (rem tod 1000000)]
    (append-date! sb days)
    (.append sb \space)
    (append-digits! sb (quot secs 3600) 2)
    (.append sb \:)
    (append-digits! sb (rem (quot secs 60) 60) 2)
    (.append sb \:)
    (append-digits! sb (rem secs 60) 2)
    (when (pos? frac)
      (.append sb \.)
      (append-digits! sb frac 6))
    sb))

(defn format-timestamp ^String [^long micros]
  (.toString (append-timestamp! (StringBuilder. 26) micros)))

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
  unscaled value (Long or, for wide p, BigInteger), or nil if not
  acceptable."
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
              u (if (empty? digits) BigInteger/ZERO (BigInteger. digits))]
          (dec-value (if neg (.negate u) u) p))))))

(defn parse-decimal-rounding
  "CAST rule: rounds half away from zero to s digits; returns the unscaled
  value, throws NUMERIC_OVERFLOW if it does not fit p, nil if malformed."
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
      :decimal (dec->string v (t/scale t))
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
    :decimal (dec->string v (t/scale t))
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
    (:int64 :date :timestamp)
    (reify Comparator
      (compare [_ a b] (Long/compare (long a) (long b))))
    :decimal (if (t/wide? t)
               (reify Comparator
                 (compare [_ a b] (.compareTo ^BigInteger a b)))
               (reify Comparator
                 (compare [_ a b] (Long/compare (long a) (long b)))))
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
    :decimal (let [s (t/scale t)] (fn ^double [x] (dec->double x s)))
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
               ;; exact for any INT64/DECIMAL operands (decimal38.md §4)
               (if (or (t/wide? lt) (t/wide? rt))
                 (fn [a b] (dec-compare-any a sl b sr))
                 (fn [a b] (dec-compare (long a) sl (long b) sr))))
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
    ;; narrow comparison types: Long, or BigInteger when the rescaled value
    ;; exceeds 64 bits; wide comparison types: always BigInteger
    :decimal (let [k (- (t/scale cmp-type) (t/scale from))]
               (if (t/wide? cmp-type)
                 (fn [x] (big-rescale-up x k))
                 (fn [x] (dec-rescale-up (long x) k))))
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
                            (if (t/wide? to)
                              (fn [v]
                                (let [x (big-rescale-up v s)]
                                  (if (big-fits? x p) x (overflow! (str "conversion to " (t/type-name to))))))
                              (fn [v]
                                (let [x (dec-rescale-up (long v) s)]
                                  (if (and (instance? Long x) (fits-precision? (long x) p))
                                    x
                                    (overflow! (str "conversion to " (t/type-name to)))))))))
        :decimal (let [s (t/scale from)]
                   (case k
                     :int64 (if (t/wide? from)
                              ;; truncation toward zero
                              (let [d (big-pow10 s)]
                                (fn [v] (let [q (.divide ^BigInteger v d)]
                                          (if (< (.bitLength q) 64)
                                            (.longValue q)
                                            (overflow! "conversion to INT64")))))
                              (fn [v] (quot (long v) (aget pow10 s))))
                     :float64 (fn [v] (dec->double v s))
                     :decimal (let [p (t/precision to) s2 (t/scale to)]
                                (if (or (t/wide? from) (t/wide? to))
                                  (fn [v] (dec-convert v s p s2))
                                  (fn [v] (dec-rescale (long v) s p s2))))))
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
