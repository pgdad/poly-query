(ns polyquery.api.values
  "The value mapping of the embedding API (spec/apps/embedding.md §1):
  conversion between the engine's runtime values (polyquery.types) and the
  native JVM values a program sees.

    INT64          java.lang.Long
    DECIMAL(p,s)   java.math.BigDecimal with scale s (exact)
    FLOAT64        java.lang.Double
    STRING         java.lang.String
    BOOLEAN        java.lang.Boolean
    DATE           java.time.LocalDate
    TIMESTAMP      java.time.LocalDateTime (no time zone)
    NULL           nil (for every type)"
  (:require [polyquery.errors :as err]
            [polyquery.types :as t]
            [polyquery.values :as v])
  (:import (java.math BigDecimal BigInteger RoundingMode)
           (java.time Instant LocalDate LocalDateTime ZoneOffset)))

(set! *warn-on-reflection* true)

(def ^:private ^:const micros-per-second 1000000)

(defn micros->local-date-time
  "A TIMESTAMP runtime value (microseconds since 1970-01-01 00:00:00) as a
  LocalDateTime."
  ^LocalDateTime [^long micros]
  (LocalDateTime/ofEpochSecond (Math/floorDiv micros micros-per-second)
                               (int (* 1000 (Math/floorMod micros micros-per-second)))
                               ZoneOffset/UTC))

(defn local-date-time->micros
  "A LocalDateTime as microseconds since 1970-01-01 00:00:00 (sub-microsecond
  digits are truncated)."
  ^long [^LocalDateTime ldt]
  (+ (* (.toEpochSecond ldt ZoneOffset/UTC) micros-per-second)
     (quot (.getNano ldt) 1000)))

(defn ->native
  "The native value of runtime value x of type typ (nil for NULL)."
  [typ x]
  (when (some? x)
    (case (t/kind typ)
      :decimal (v/dec->bigdec x (t/scale typ))
      :date (LocalDate/ofEpochDay (long x))
      :timestamp (micros->local-date-time (long x))
      x)))

;; ---------------------------------------------------------------------------
;; Native → runtime (polyquery.api/load-rows!)

(def ^:private min-date (LocalDate/of 1 1 1))
(def ^:private max-date (LocalDate/of 9999 12 31))

(defn- mismatch! [typ x]
  (err/fail! "INVALID_REQUEST"
             (str "a " (t/type-name typ) " value cannot be given as "
                  (if (nil? x) "nil" (.getName (class x))))))

(defn- integral-big
  "x as a BigInteger when it is an integral Java/Clojure number, else nil."
  ^BigInteger [x]
  (cond
    (or (instance? Long x) (instance? Integer x) (instance? Short x) (instance? Byte x))
    (BigInteger/valueOf (long x))
    (instance? BigInteger x) x
    (instance? clojure.lang.BigInt x) (.toBigInteger ^clojure.lang.BigInt x)
    :else nil))

(defn- ->bigdec ^BigDecimal [typ x]
  (cond
    (instance? BigDecimal x) x
    (integral-big x) (BigDecimal. (integral-big x))
    :else (mismatch! typ x)))

(defn- check-date-range! [^LocalDate d]
  (when (or (.isBefore d min-date) (.isAfter d max-date))
    (err/fail! "NUMERIC_OVERFLOW" (str "date " d " is outside 0001-01-01 … 9999-12-31"))))

(defn ->runtime
  "The runtime value of native value x for a column of type typ; throws
  INVALID_REQUEST for a value of the wrong class, CONVERSION_ERROR for a
  decimal with more fractional digits than the scale and NUMERIC_OVERFLOW
  for a value outside the type's range."
  [typ x]
  (when (some? x)
    (case (t/kind typ)
      :boolean (if (boolean? x) x (mismatch! typ x))
      :int64 (if-let [b (integral-big x)]
               (if (< (.bitLength b) 64) (.longValue b) (v/overflow! "INT64 value"))
               (mismatch! typ x))
      :float64 (if (or (instance? Double x) (instance? Float x) (integral-big x)
                       (instance? BigDecimal x))
                 (v/check-finite (double x) "FLOAT64 value")
                 (mismatch! typ x))
      :decimal (let [bd (->bigdec typ x)
                     s (t/scale typ)
                     scaled (try (.setScale bd (int s) RoundingMode/UNNECESSARY)
                                 (catch ArithmeticException _
                                   (err/fail! "CONVERSION_ERROR"
                                              (str "value " bd " has more than " s " fractional digits"))))]
                 (v/bigdec->unscaled scaled (t/precision typ) s))
      :string (if (string? x) x (mismatch! typ x))
      :date (if (instance? LocalDate x)
              (do (check-date-range! x) (.toEpochDay ^LocalDate x))
              (mismatch! typ x))
      :timestamp (let [ldt (cond
                             (instance? LocalDateTime x) x
                             (instance? Instant x) (LocalDateTime/ofInstant ^Instant x ZoneOffset/UTC)
                             :else (mismatch! typ x))]
                   (check-date-range! (.toLocalDate ^LocalDateTime ldt))
                   (local-date-time->micros ldt)))))
