(ns polyquery.exec.expr
  "Compiles bound expressions (polyquery.sql.analyzer) into closures
  `(fn [^objects row] value)`, specialised on the static operand types
  (spec/data-types/types.md §4-§6, §8)."
  (:require [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.types :as t]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(defn- overflow! [] (err/fail! "NUMERIC_OVERFLOW" "integer overflow"))
(defn- div-zero! [] (err/fail! "DIVISION_BY_ZERO" "division by zero"))

(declare compile-expr)

;; ---------------------------------------------------------------------------
;; Operand conversions

(defn- ->double-fn
  "Function converting a non-null value of numeric type t to double."
  [t]
  (case (t/kind t)
    :int64 (fn ^double [x] (double (long x)))
    :float64 (fn ^double [x] (double x))
    :decimal (let [s (t/scale t)] (fn ^double [x] (v/dec->double (long x) s)))
    :null (fn ^double [_] 0.0)))

(defn- binary-op
  "Wraps a two-argument function on non-null operands with NULL propagation."
  [lf rf f]
  (fn [row]
    (let [a (lf row)]
      (when (some? a)
        (let [b (rf row)]
          (when (some? b)
            (f a b)))))))

;; ---------------------------------------------------------------------------
;; Arithmetic

(defn- int-arith [op]
  (case op
    "+" (fn [a b] (try (Math/addExact (long a) (long b)) (catch ArithmeticException _ (overflow!))))
    "-" (fn [a b] (try (Math/subtractExact (long a) (long b)) (catch ArithmeticException _ (overflow!))))
    "*" (fn [a b] (try (Math/multiplyExact (long a) (long b)) (catch ArithmeticException _ (overflow!))))
    "/" (fn [a b]
          (let [a (long a) b (long b)]
            (cond (zero? b) (div-zero!)
                  (and (= a Long/MIN_VALUE) (= b -1)) (overflow!)
                  :else (quot a b))))
    "%" (fn [a b]
          (let [a (long a) b (long b)]
            (if (zero? b) (div-zero!) (rem a b))))))

(defn- float-arith [op lt rt]
  (let [dl (->double-fn lt) dr (->double-fn rt)
        finite (fn [^double d] (if (or (Double/isInfinite d) (Double/isNaN d))
                                 (err/fail! "NUMERIC_OVERFLOW" "floating point overflow")
                                 d))]
    (case op
      "+" (fn [a b] (finite (+ (double (dl a)) (double (dr b)))))
      "-" (fn [a b] (finite (- (double (dl a)) (double (dr b)))))
      "*" (fn [a b] (finite (* (double (dl a)) (double (dr b)))))
      "/" (fn [a b] (let [y (double (dr b))]
                      (if (== y 0.0) (div-zero!) (finite (/ (double (dl a)) y))))))))

(defn- decimal-arith [op lt rt]
  (let [sl (t/scale lt) sr (t/scale rt)]
    (case op
      "+" (fn [a b] (v/dec-add (long a) sl (long b) sr))
      "-" (fn [a b] (v/dec-add (long a) sl (- (long b)) sr))
      "*" (fn [a b] (v/dec-mul (long a) (long b))))))

(defn- compile-arith [c e]
  (let [{:keys [op type left right]} e
        lt (:type left) rt (:type right)
        f (case (t/kind type)
            :null nil
            :int64 (int-arith op)
            :float64 (float-arith op lt rt)
            :decimal (decimal-arith op lt rt))]
    (if f
      (binary-op (compile-expr c left) (compile-expr c right) f)
      (constantly nil))))

(defn- compile-neg [c e]
  (let [af (compile-expr c (:arg e))]
    (case (t/kind (:type e))
      :int64 (fn [row] (when-let [x (af row)]
                         (if (= (long x) Long/MIN_VALUE) (overflow!) (- (long x)))))
      :decimal (fn [row] (when-let [x (af row)] (- (long x))))
      :float64 (fn [row] (when-let [x (af row)] (- (double x))))
      :null (constantly nil))))

;; ---------------------------------------------------------------------------
;; Comparison

(defn- comparator-fn
  "Returns (fn [a b]) → negative/zero/positive for non-null operands of the
  given types compared as cmp-type."
  [cmp-type lt rt]
  (case (t/kind cmp-type)
    :int64 (fn [a b] (Long/compare (long a) (long b)))
    :float64 (let [dl (->double-fn lt) dr (->double-fn rt)]
               (fn [a b] (let [x (double (dl a)) y (double (dr b))]
                           (cond (< x y) -1 (> x y) 1 :else 0))))
    :decimal (let [sl (t/scale lt) sr (t/scale rt)]
               (fn [a b] (v/dec-compare (long a) sl (long b) sr)))
    :timestamp (let [conv (fn [t] (if (= t :date)
                                    (fn ^long [x] (* (long x) v/micros-per-day))
                                    (fn ^long [x] (long x))))
                     cl (conv lt) cr (conv rt)]
                 (fn [a b] (Long/compare (long (cl a)) (long (cr b)))))
    (let [cmp (v/value-comparator cmp-type)]
      (fn [a b] (.compare cmp a b)))))

(defn- compile-compare [c e]
  (let [{:keys [op cmp-type left right]} e
        cmp (comparator-fn cmp-type (:type left) (:type right))
        test (case op
               "=" zero? "<>" (complement zero?) "<" neg? "<=" (complement pos?)
               ">" pos? ">=" (complement neg?))]
    (if (= cmp-type :null)
      (constantly nil)
      (binary-op (compile-expr c left) (compile-expr c right)
                 (fn [a b] (boolean (test (long (cmp a b)))))))))

;; ---------------------------------------------------------------------------
;; Logic

(defn- compile-and [c e]
  (let [lf (compile-expr c (:left e)) rf (compile-expr c (:right e))]
    (fn [row]
      (let [a (lf row)]
        (if (false? a)
          false
          (let [b (rf row)]
            (cond (false? b) false
                  (or (nil? a) (nil? b)) nil
                  :else true)))))))

(defn- compile-or [c e]
  (let [lf (compile-expr c (:left e)) rf (compile-expr c (:right e))]
    (fn [row]
      (let [a (lf row)]
        (if (true? a)
          true
          (let [b (rf row)]
            (cond (true? b) true
                  (or (nil? a) (nil? b)) nil
                  :else false)))))))

;; ---------------------------------------------------------------------------
;; Functions

(defn- compile-call [c e]
  (let [args (mapv #(compile-expr c %) (:args e))]
    (case (:fn e)
      "PQ_SLEEP" (let [af (first args) qctx (:ctx c)]
                   (fn [row]
                     (when-let [ms (af row)]
                       (when (neg? (long ms))
                         (err/fail! "INVALID_ARGUMENT" "PQ_SLEEP expects a non-negative duration"))
                       (ctx/sleep! qctx (long ms))
                       ms))))))

;; ---------------------------------------------------------------------------

(defn compile-expr
  "Compiles bound expression e. `c` is the compilation environment
  {:ctx QueryContext}."
  [c e]
  (case (:node e)
    :literal (let [x (:value e)] (fn [_] x))
    :column (let [i (int (:index e))] (fn [^objects row] (aget row i)))
    :neg (compile-neg c e)
    :arith (compile-arith c e)
    :concat (binary-op (compile-expr c (:left e)) (compile-expr c (:right e))
                       (fn [a b] (str a b)))
    :compare (compile-compare c e)
    :and (compile-and c e)
    :or (compile-or c e)
    :not (let [af (compile-expr c (:arg e))]
           (fn [row] (let [x (af row)] (when (some? x) (not x)))))
    :is-null (let [af (compile-expr c (:arg e)) not? (boolean (:not? e))]
               (fn [row] (if not? (some? (af row)) (nil? (af row)))))
    :cast (let [af (compile-expr c (:arg e))
                f (v/cast-fn (:type (:arg e)) (:type e))]
            (fn [row] (let [x (af row)] (when (some? x) (f x)))))
    :call (compile-call c e)))

(defn compile-predicate
  "Compiles a boolean expression into a function returning true only when
  the expression is TRUE (NULL counts as not true)."
  [c e]
  (let [f (compile-expr c e)]
    (fn [row] (true? (f row)))))

(defn eval-constant
  "Evaluates a row-independent expression."
  [c e]
  ((compile-expr c e) (object-array 0)))
