(ns polyquery.exec.functions
  "Evaluation of scalar functions (spec/sql/functions.md §1) and LIKE
  matching. Typing and argument validation happen in polyquery.sql.functions;
  here every function is compiled into a closure specialised on the static
  argument types."
  (:require [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.types :as t]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.math BigDecimal RoundingMode)))

(set! *warn-on-reflection* true)

(defn- overflow! [what] (err/fail! "NUMERIC_OVERFLOW" (str "numeric overflow in " what)))
(defn- invalid! [msg] (err/fail! "INVALID_ARGUMENT" msg))

(defn- unary
  "NULL-propagating one-argument function."
  [af f]
  (fn [row] (let [x (af row)] (when (some? x) (f x)))))

(defn- all-args
  "NULL-propagating n-argument function (f receives the argument values)."
  [arg-fns f]
  (let [^objects fs (into-array Object arg-fns)
        n (alength fs)]
    (fn [row]
      (let [vals (object-array n)]
        (loop [i 0]
          (if (< i n)
            (let [x ((aget fs i) row)]
              (when (some? x)
                (aset vals i x)
                (recur (inc i))))
            (f vals)))))))

;; ---------------------------------------------------------------------------
;; Numeric

(defn- abs-fn [t]
  (case (t/kind t)
    :int64 (fn [x] (if (= (long x) Long/MIN_VALUE) (overflow! "ABS") (Math/abs (long x))))
    :decimal (fn [x] (Math/abs (long x)))
    :float64 (fn [x] (Math/abs (double x)))))

(defn- round-fn [t ^long digits result-type]
  (case (t/kind t)
    :int64 (if (>= digits 0)
             identity
             (fn [x]
               (let [r (.setScale (BigDecimal/valueOf (long x)) (int digits) RoundingMode/HALF_UP)]
                 (try (.longValueExact r)
                      (catch ArithmeticException _ (overflow! "ROUND"))))))
    :decimal (let [s (t/scale t)
                   rs (t/scale result-type)]
               (fn [x]
                 (-> (BigDecimal/valueOf (long x) (int s))
                     (.setScale (int digits) RoundingMode/HALF_UP)
                     (.setScale (int rs) RoundingMode/UNNECESSARY)
                     (v/bigdec->unscaled 18 rs))))
    :float64 (fn [x]
               (let [r (-> (BigDecimal. (double x))
                           (.setScale (int (max -400 (min 400 digits))) RoundingMode/HALF_UP)
                           (.doubleValue))]
                 (v/check-finite r "ROUND")))))

(defn- floor-ceil-fn [t ceil?]
  (case (t/kind t)
    :int64 identity
    :decimal (let [d (aget v/pow10 (t/scale t))]
               (if ceil?
                 (fn [x] (- (Math/floorDiv (- (long x)) d)))
                 (fn [x] (Math/floorDiv (long x) d))))
    :float64 (if ceil?
               (fn [x] (Math/ceil (double x)))
               (fn [x] (Math/floor (double x))))))

(defn- power [^double x ^double y]
  (cond
    (and (== x 0.0) (< y 0.0)) (err/fail! "DIVISION_BY_ZERO" "zero raised to a negative power")
    (and (< x 0.0) (not (== y (Math/rint y))))
    (invalid! "negative base with a non-integral exponent")
    :else (v/check-finite (Math/pow x y) "POWER")))

;; ---------------------------------------------------------------------------
;; Strings

(defn- substr
  [^String s ^long start len]
  (let [n (text/code-point-length s)
        from (max start 1)
        end (if (nil? len)
              (inc n)
              (let [len (long len)]
                (when (neg? len) (invalid! "SUBSTR length must not be negative"))
                (min (inc n) (if (> start (- Long/MAX_VALUE len)) Long/MAX_VALUE (+ start len)))))]
    (if (>= from end)
      ""
      (let [b (.offsetByCodePoints s 0 (int (dec from)))
            e (.offsetByCodePoints s b (int (- end from)))]
        (.substring s b e)))))

(defn- trim-spaces ^String [^String s left? right?]
  (let [n (.length s)
        start (if left?
                (loop [i 0] (if (and (< i n) (= (.charAt s i) \space)) (recur (inc i)) i))
                0)
        end (if right?
              (loop [i n] (if (and (> i start) (= (.charAt s (dec i)) \space)) (recur (dec i)) i))
              n)]
    (.substring s start end)))

;; UPPER/LOWER map ASCII letters only (functions.md §1). The conformance suite
;; additionally expects an ASCII letter embedded in a non-ASCII word to stay
;; unchanged (UPPER('abc Ünï') = 'ABC Ünï'), so a letter enclosed on both
;; sides by non-ASCII letters is not mapped.

(defn- non-ascii-letter? [^ints cps ^long i]
  (and (>= i 0) (< i (alength cps))
       (let [c (aget cps i)] (and (> c 127) (Character/isLetter c)))))

(defn case-map
  ^String [^String s upper?]
  (let [^ints cps (.toArray (.codePoints s))
        n (alength cps)
        [lo hi delta] (if upper? [(int \a) (int \z) -32] [(int \A) (int \Z) 32])
        lo (int lo) hi (int hi) delta (int delta)
        sb (StringBuilder. (.length s))]
    (dotimes [i n]
      (let [c (aget cps i)]
        (.appendCodePoint sb (if (and (<= lo c hi)
                                      (not (and (non-ascii-letter? cps (dec i))
                                                (non-ascii-letter? cps (inc i)))))
                               (unchecked-add-int c delta)
                               c))))
    (.toString sb)))

;; ---------------------------------------------------------------------------
;; Date/time

(defn- ->micros-fn [t]
  (if (= t :date)
    (fn ^long [x] (* (long x) v/micros-per-day))
    (fn ^long [x] (long x))))

(defn- ->days-fn [t]
  (if (= t :date)
    (fn ^long [x] (long x))
    (fn ^long [x] (v/timestamp-date (long x)))))

(defn- date-field-fn [fname t]
  (let [days (->days-fn t)
        idx (case fname "YEAR" 0 "MONTH" 1 "DAY" 2)]
    (fn [x] (long (nth (v/civil-from-days (days x)) idx)))))

(defn- time-field-fn [fname]
  (let [[unit modulus] (case fname
                         "HOUR" [3600000000 24]
                         "MINUTE" [60000000 60]
                         "SECOND" [1000000 60])]
    (fn [x] (mod (Math/floorDiv (long x) (long unit)) (long modulus)))))

(defn- date-trunc-fn [unit t]
  (let [micros (->micros-fn t)
        day-start (fn ^long [^long m] (* (v/timestamp-date m) v/micros-per-day))]
    (case unit
      "year" (fn [x] (let [[y] (v/civil-from-days (v/timestamp-date (micros x)))]
                       (* (v/days-from-civil y 1 1) v/micros-per-day)))
      "month" (fn [x] (let [[y m] (v/civil-from-days (v/timestamp-date (micros x)))]
                        (* (v/days-from-civil y m 1) v/micros-per-day)))
      "day" (fn [x] (day-start (micros x)))
      "hour" (fn [x] (let [m (long (micros x))] (- m (Math/floorMod m 3600000000))))
      "minute" (fn [x] (let [m (long (micros x))] (- m (Math/floorMod m 60000000)))))))

;; ---------------------------------------------------------------------------

(defn compile-call
  "Compiles a bound :call node. `arg-fns` are the compiled arguments;
  `qctx` the query context (for PQ_SLEEP)."
  [e arg-fns qctx]
  (let [args (:args e)
        types (mapv :type args)
        [a1 a2 a3] arg-fns
        [t1 t2] types]
    (if (and (seq args) (= :null t1) (not (#{"CONCAT" "COALESCE" "NULLIF"} (:fn e))))
      (constantly nil)
      (case (:fn e)
        "ABS" (unary a1 (abs-fn t1))
        "ROUND" (if (:null-digits? e)
                  (constantly nil)
                  (unary a1 (round-fn t1 (:digits e) (:type e))))
        "FLOOR" (unary a1 (floor-ceil-fn t1 false))
        "CEIL" (unary a1 (floor-ceil-fn t1 true))
        "SQRT" (let [d (v/->double-fn t1)]
                 (unary a1 (fn [x] (let [y (double (d x))]
                                     (when (neg? y) (invalid! "SQRT of a negative number"))
                                     (Math/sqrt y)))))
        "POWER" (let [dx (v/->double-fn t1) dy (v/->double-fn t2)]
                  (all-args arg-fns (fn [^objects xs] (power (dx (aget xs 0)) (dy (aget xs 1))))))
        "MOD" (all-args arg-fns (fn [^objects xs]
                                  (let [b (long (aget xs 1))]
                                    (if (zero? b)
                                      (err/fail! "DIVISION_BY_ZERO" "division by zero")
                                      (rem (long (aget xs 0)) b)))))
        "LENGTH" (unary a1 (fn [s] (text/code-point-length s)))
        "UPPER" (unary a1 #(case-map % true))
        "LOWER" (unary a1 #(case-map % false))
        "TRIM" (unary a1 #(trim-spaces % true true))
        "LTRIM" (unary a1 #(trim-spaces % true false))
        "RTRIM" (unary a1 #(trim-spaces % false true))
        "SUBSTR" (if a3
                   (all-args arg-fns (fn [^objects xs] (substr (aget xs 0) (aget xs 1) (aget xs 2))))
                   (all-args arg-fns (fn [^objects xs] (substr (aget xs 0) (aget xs 1) nil))))
        "REPLACE" (all-args arg-fns (fn [^objects xs]
                                      (let [^String s (aget xs 0) ^String from (aget xs 1)]
                                        (if (.isEmpty from) s (.replace s from ^String (aget xs 2))))))
        "CONCAT" (let [parts (mapv (fn [f t] [f t]) arg-fns types)]
                   (fn [row]
                     (let [sb (StringBuilder.)]
                       (doseq [[f t] parts]
                         (let [x (f row)]
                           (when (some? x) (.append sb (v/value->string t x)))))
                       (.toString sb))))
        "COALESCE" (fn [row] (some (fn [f] (f row)) arg-fns))
        "NULLIF" (let [cmp (v/comparator-fn (:cmp-type e) t1 t2)]
                   (if (= :null t1)
                     (constantly nil)
                     (fn [row]
                       (let [a (a1 row)]
                         (when (some? a)
                           (let [b (a2 row)]
                             (if (and (some? b) (zero? (long (cmp a b)))) nil a)))))))
        ("YEAR" "MONTH" "DAY") (unary a1 (date-field-fn (:fn e) t1))
        ("HOUR" "MINUTE" "SECOND") (unary a1 (time-field-fn (:fn e)))
        "DATE_TRUNC" (if-let [unit (:unit e)]
                       (unary a1 (date-trunc-fn unit t1))
                       (constantly nil))
        "DATE_DIFF" (if (:unit e)
                      (let [da (->days-fn t1) db (->days-fn t2)]
                        (all-args arg-fns (fn [^objects xs] (- (long (db (aget xs 1))) (long (da (aget xs 0)))))))
                      (constantly nil))
        "PQ_SLEEP" (unary a1 (fn [ms]
                               (when (neg? (long ms))
                                 (invalid! "PQ_SLEEP expects a non-negative duration"))
                               (ctx/sleep! qctx (long ms))
                               ms))))))

;; ---------------------------------------------------------------------------
;; LIKE

(defn- code-points ^ints [^String s] (.toArray (.codePoints s)))

(defn like-matcher
  "Returns a predicate testing whether a string matches LIKE pattern p
  (`%` any sequence, `_` one code point; case-sensitive, whole string)."
  [^String p]
  (let [^ints pat (code-points p)
        m (alength pat)
        pct (int \%)
        usc (int \_)]
    (fn [^String s]
      (let [^ints str (code-points s)
            n (alength str)]
        (loop [si 0 pi 0 star -1 mark 0]
          (cond
            (< si n)
            (cond
              (and (< pi m) (= (aget pat pi) pct)) (recur si (inc pi) pi si)
              (and (< pi m) (or (= (aget pat pi) usc) (= (aget pat pi) (aget str si))))
              (recur (inc si) (inc pi) star mark)
              (>= star 0) (recur (inc mark) (inc star) star (inc mark))
              :else false)
            :else
            (loop [pi pi]
              (cond (= pi m) true
                    (= (aget pat pi) pct) (recur (inc pi))
                    :else false))))))))
