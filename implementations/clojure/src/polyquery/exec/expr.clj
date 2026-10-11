(ns polyquery.exec.expr
  "Compiles bound expressions (polyquery.sql.bound) into closures
  `(fn [^objects row] value)`, specialised on the static operand types
  (spec/data-types/types.md §4-§8, spec/sql/semantics.md §8, §11-13).

  The compilation environment `c` holds:
    :ctx    the QueryContext (timeouts, cancellation)
    :cells  atom of cell id → Object[1] holding the current row of an
            enclosing query (correlated subqueries)
    :build  (fn [physical-plan c]) → re-reducible of rows; used to compile
            the nested plans of subquery expressions"
  (:require [polyquery.errors :as err]
            [polyquery.exec.functions :as functions]
            [polyquery.types :as t]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(defn- overflow! [] (err/fail! "NUMERIC_OVERFLOW" "integer overflow"))
(defn- div-zero! [] (err/fail! "DIVISION_BY_ZERO" "division by zero"))

(declare compile-expr)

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
  (let [dl (v/->double-fn lt) dr (v/->double-fn rt)
        finite (fn [^double d] (if (or (Double/isInfinite d) (Double/isNaN d))
                                 (err/fail! "NUMERIC_OVERFLOW" "floating point overflow")
                                 d))]
    (case op
      "+" (fn [a b] (finite (+ (double (dl a)) (double (dr b)))))
      "-" (fn [a b] (finite (- (double (dl a)) (double (dr b)))))
      "*" (fn [a b] (finite (* (double (dl a)) (double (dr b)))))
      "/" (fn [a b] (let [y (double (dr b))]
                      (if (== y 0.0) (div-zero!) (finite (/ (double (dl a)) y))))))))

(defn- decimal-arith
  "DECIMAL + - *: long arithmetic for narrow results, BigInteger arithmetic
  for wide ones (the result type is wide iff an operand is wide)."
  [op lt rt type]
  (let [sl (t/scale lt) sr (t/scale rt)]
    (if (t/wide? type)
      (case op
        "+" (fn [a b] (v/wide-add a sl b sr))
        "-" (fn [a b] (v/wide-sub a sl b sr))
        "*" (fn [a b] (v/wide-mul a b)))
      (case op
        "+" (fn [a b] (v/dec-add (long a) sl (long b) sr))
        "-" (fn [a b] (v/dec-add (long a) sl (- (long b)) sr))
        "*" (fn [a b] (v/dec-mul (long a) (long b)))))))

(defn- compile-arith [c e]
  (let [{:keys [op type left right]} e
        lt (:type left) rt (:type right)
        f (case (t/kind type)
            :null nil
            :int64 (int-arith op)
            :float64 (float-arith op lt rt)
            :decimal (decimal-arith op lt rt type))]
    (if f
      (binary-op (compile-expr c left) (compile-expr c right) f)
      (constantly nil))))

(defn- compile-neg [c e]
  (let [af (compile-expr c (:arg e))]
    (case (t/kind (:type e))
      :int64 (fn [row] (when-let [x (af row)]
                         (if (= (long x) Long/MIN_VALUE) (overflow!) (- (long x)))))
      :decimal (fn [row] (when-let [x (af row)] (v/dec-negate x)))
      :float64 (fn [row] (when-let [x (af row)] (- (double x))))
      :null (constantly nil))))

;; ---------------------------------------------------------------------------
;; Comparison

(defn- cmp-test [op]
  (case op
    "=" zero? "<>" (complement zero?) "<" neg? "<=" (complement pos?)
    ">" pos? ">=" (complement neg?)))

(defn- compile-compare [c e]
  (let [{:keys [op cmp-type left right]} e
        cmp (v/comparator-fn cmp-type (:type left) (:type right))
        test (cmp-test op)]
    (if (= cmp-type :null)
      (constantly nil)
      (binary-op (compile-expr c left) (compile-expr c right)
                 (fn [a b] (boolean (test (long (cmp a b)))))))))

(defn- three-valued-cmp
  "(fn [x y]) → nil if either is NULL, else (test (cmp x y))."
  [cmp-type lt rt test]
  (if (= cmp-type :null)
    (constantly nil)
    (let [cmp (v/comparator-fn cmp-type lt rt)]
      (fn [x y] (when (and (some? x) (some? y)) (boolean (test (long (cmp x y)))))))))

(defn- and3 [a b]
  (cond (or (false? a) (false? b)) false
        (or (nil? a) (nil? b)) nil
        :else true))

(defn- not3 [x] (when (some? x) (not x)))

(defn- compile-between [c e]
  (let [xt (:type (:arg e))
        xf (compile-expr c (:arg e))
        lf (compile-expr c (:low e))
        hf (compile-expr c (:high e))
        ge (three-valued-cmp (:low-type e) xt (:type (:low e)) (complement neg?))
        le (three-valued-cmp (:high-type e) xt (:type (:high e)) (complement pos?))
        not? (:not? e)]
    (fn [row]
      (let [x (xf row)
            r (and3 (ge x (lf row)) (le x (hf row)))]
        (if not? (not3 r) r)))))

(defn- compile-in-list [c e]
  (let [xt (:type (:arg e))
        xf (compile-expr c (:arg e))
        items (mapv (fn [item ct]
                      [(compile-expr c item)
                       (if (= ct :null) nil (v/comparator-fn ct xt (:type item)))])
                    (:items e) (:cmp-types e))
        not? (:not? e)]
    (fn [row]
      (let [x (xf row)
            r (when (some? x)
                (loop [items items saw-null? false]
                  (if-let [[f cmp] (first items)]
                    (let [y (f row)]
                      (cond
                        (or (nil? y) (nil? cmp)) (recur (rest items) true)
                        (zero? (long (cmp x y))) true
                        :else (recur (rest items) saw-null?)))
                    (if saw-null? nil false))))]
        (if not? (not3 r) r)))))

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
;; CASE / LIKE

(defn- compile-case [c e]
  (let [whens (mapv (fn [[w r]] [(compile-expr c w) (compile-expr c r)]) (:whens e))
        else-f (if (:else e) (compile-expr c (:else e)) (constantly nil))]
    (fn [row]
      (loop [ws whens]
        (if-let [[w r] (first ws)]
          (if (true? (w row)) (r row) (recur (rest ws)))
          (else-f row))))))

(defn- compile-like [c e]
  (let [xf (compile-expr c (:arg e))
        pat (:pattern e)
        not? (:not? e)
        matcher (if (= :literal (:node pat))
                  (let [m (when (some? (:value pat)) (functions/like-matcher (:value pat)))]
                    (fn [_] m))
                  (let [pf (compile-expr c pat)
                        cache (volatile! nil)]
                    (fn [row]
                      (when-let [p (pf row)]
                        (let [[cp m] @cache]
                          (if (= cp p)
                            m
                            (let [m (functions/like-matcher p)]
                              (vreset! cache [p m])
                              m)))))))]
    (fn [row]
      (let [x (xf row)
            m (when (some? x) (matcher row))]
        (when (and (some? x) m)
          (let [r (boolean (m x))]
            (if not? (not r) r)))))))

;; ---------------------------------------------------------------------------
;; Correlation cells and subqueries

(defn cell-holder
  "The Object[1] holding the current outer row for correlation cell id."
  ^objects [c id]
  (let [cells (:cells c)]
    (or (get @cells id)
        (get (swap! cells (fn [m] (if (contains? m id) m (assoc m id (object-array 1))))) id))))

(defn- once
  "Memoizes a function of the row for uncorrelated subqueries: computed on
  first use, then reused."
  [f]
  (let [result (volatile! ::unset)]
    (fn [row]
      (let [r @result]
        (if (identical? r ::unset)
          (let [x (f row)] (vreset! result x) x)
          r)))))

(defn- scalar-value [plan]
  (let [r (reduce (fn [acc ^objects row]
                    (if (identical? acc ::none)
                      (aget row 0)
                      (err/fail! "SUBQUERY_CARDINALITY" "scalar subquery returned more than one row")))
                  ::none plan)]
    (when-not (identical? r ::none) r)))

(defn- value-set
  "[java.util.HashSet of keys, has-null?] of the single column of plan."
  [plan key-fn]
  (let [s (java.util.HashSet.)
        has-null (volatile! false)]
    (reduce (fn [_ ^objects row]
              (let [x (aget row 0)]
                (if (nil? x) (vreset! has-null true) (.add s (key-fn x))))
              nil)
            nil plan)
    [s @has-null]))

(defn- compile-subquery [c e]
  (let [^objects holder (cell-holder c (:cell e))
        plan ((:build c) (:plan e) c)
        with-row (fn [f] (fn [row] (aset holder 0 row) (f)))
        memo (if (:correlated? e) identity once)]
    (case (:kind e)
      :scalar (memo (with-row #(scalar-value plan)))
      :exists (memo (with-row #(reduce (fn [_ _] (reduced true)) false plan)))
      :in (let [ct (:cmp-type e)
                col-type (:type (first (:columns (:plan e))))
                xt (:type (:arg e))
                xf (compile-expr c (:arg e))
                set-of (memo (with-row #(value-set plan (v/key-fn col-type ct))))
                xkey (v/key-fn xt ct)
                not? (:not? e)]
            (fn [row]
              (let [x (xf row)
                    [^java.util.HashSet s has-null?] (set-of row)
                    r (cond
                        (.isEmpty s) (if has-null? nil false)
                        (nil? x) nil
                        (.contains s (xkey x)) true
                        has-null? nil
                        :else false)]
                (if not? (not3 r) r)))))))

(defn in-set-fn
  "Three-valued test of an :in-set node (polyquery.sql.bound) for a value x
  of its argument — the result of the IN subquery it replaces."
  [e]
  (let [^java.util.Set s (:keys e)
        none? (.isEmpty s)
        has-null? (boolean (:has-null? e))
        xkey (v/key-fn (:type (:arg e)) (:cmp-type e))
        not? (:not? e)]
    (fn [x]
      (let [r (cond
                none? (if has-null? nil false)
                (nil? x) nil
                (.contains s (xkey x)) true
                has-null? nil
                :else false)]
        (if not? (not3 r) r)))))

(defn- compile-in-set [c e]
  (let [xf (compile-expr c (:arg e))
        test (in-set-fn e)]
    (fn [row] (test (xf row)))))

;; ---------------------------------------------------------------------------

(defn compile-expr
  "Compiles bound expression e in environment c."
  [c e]
  (case (:node e)
    :literal (let [x (:value e)] (fn [_] x))
    :column (let [i (int (:index e))] (fn [^objects row] (aget row i)))
    :outer-column (let [^objects holder (cell-holder c (:cell e))
                        i (int (:index e))]
                    (fn [_] (aget ^objects (aget holder 0) i)))
    :neg (compile-neg c e)
    :arith (compile-arith c e)
    :concat (binary-op (compile-expr c (:left e)) (compile-expr c (:right e))
                       (fn [a b] (str a b)))
    :compare (compile-compare c e)
    :and (compile-and c e)
    :or (compile-or c e)
    :not (let [af (compile-expr c (:arg e))]
           (fn [row] (not3 (af row))))
    :is-null (let [af (compile-expr c (:arg e)) not? (boolean (:not? e))]
               (fn [row] (if not? (some? (af row)) (nil? (af row)))))
    :cast (let [af (compile-expr c (:arg e))
                f (v/cast-fn (:type (:arg e)) (:type e))]
            (fn [row] (let [x (af row)] (when (some? x) (f x)))))
    :call (functions/compile-call e (mapv #(compile-expr c %) (:args e)) (:ctx c))
    :case (compile-case c e)
    :like (compile-like c e)
    :between (compile-between c e)
    :in-list (compile-in-list c e)
    :in-set (compile-in-set c e)
    :subquery (compile-subquery c e)))

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
