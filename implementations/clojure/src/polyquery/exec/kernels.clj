(ns polyquery.exec.kernels
  "Vectorized expression evaluation: compiles bound expressions
  (polyquery.sql.bound) into *kernels* that evaluate an expression for the
  selected rows of a batch (polyquery.exec.batch) at once, producing a typed
  vector.

  Kernels mirror the row-at-a-time compiler (polyquery.exec.expr) exactly:
  the same NULL propagation, the same overflow/division checks, and the same
  laziness — the right operand of AND (OR) is only evaluated on rows where
  the left one is not FALSE (TRUE), CASE branches and COALESCE arguments only
  on the rows that reach them, and the right operand of a NULL-propagating
  operator only on rows where the left one is not NULL when it could fail.
  So a vectorized evaluation never raises an error the row engine would not.

  The hot paths (column/constant comparisons, integer/decimal/float
  arithmetic, boolean logic, IN lists, LIKE, casts) are tight loops over
  primitive arrays; with the identity selection they have no indirection and
  the JIT can unroll and auto-vectorize them. Comparisons against
  dictionary-encoded strings are evaluated once per dictionary entry.
  Expressions without a vectorized implementation (subqueries, correlated
  references, functions with failing arguments, arithmetic and comparisons
  over wide DECIMAL values) fall back to the row closure, applied per
  selected row. Wide DECIMAL values (BigIntegers) travel in ObjVecs."
  (:require [polyquery.errors :as err]
            [polyquery.exec.batch :as b :refer [each-sel]]
            [polyquery.exec.expr :as expr]
            [polyquery.exec.functions :as functions]
            [polyquery.sql.bound :as bound]
            [polyquery.types :as t]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (polyquery.exec.batch Batch BoolVec DictVec DoubleVec LazyCol LongVec ObjVec Vec)
           (java.util HashSet IdentityHashMap)))

(set! *warn-on-reflection* true)

(definterface Kernel
  (eval [^polyquery.exec.batch.Batch b ^ints sel ^long n]
        "Vector of the expression's values at the selected positions."))

(defn ev
  "Evaluates kernel k on the selection (sel, n) of batch bt."
  ^polyquery.exec.batch.Vec [^Kernel k ^Batch bt ^ints sel n]
  (.eval k bt sel (long n)))

(def ^:private ^:const cap b/capacity)

(defn- overflow! [] (err/fail! "NUMERIC_OVERFLOW" "integer overflow"))
(defn- float-overflow! [] (err/fail! "NUMERIC_OVERFLOW" "floating point overflow"))
(defn- div-zero! [] (err/fail! "DIVISION_BY_ZERO" "division by zero"))

(declare compile-kernel)

;; ---------------------------------------------------------------------------
;; Null masks and selections

(defn nulls-of
  "Null mask of the selected positions of any vector (nil when none is
  NULL)."
  ^booleans [^Vec x ^ints sel n]
  (cond
    (instance? LongVec x) (.-nulls ^LongVec x)
    (instance? DoubleVec x) (.-nulls ^DoubleVec x)
    (instance? BoolVec x) (.-nulls ^BoolVec x)
    (instance? DictVec x) (.-nulls ^DictVec x)
    :else (let [n (long n)
                out (boolean-array cap)
                any? (loop [k 0 any? false]
                       (if (< k n)
                         (let [i (aget sel k)
                               nul (.isNullAt x i)]
                           (aset out i nul)
                           (recur (inc k) (or any? nul)))
                         any?))]
            (when any? out))))

(defn- union-nulls
  ^booleans [^booleans a ^booleans c ^ints sel ^long n]
  (cond
    (nil? a) c
    (nil? c) a
    :else (let [out (boolean-array cap)]
            (each-sel [i sel n] (aset out i (or (aget a i) (aget c i))))
            out)))

(defn- non-null-sel
  "[sel' n'] of the positions of (sel, n) that are not NULL in mask."
  [^booleans nulls ^ints sel ^long n]
  (b/positions-where sel n (fn [^long i] (not (aget nulls i)))))

(defn may-fail?
  "True when evaluating e can raise an error for some row."
  [e]
  (let [kids-fail? #(boolean (some may-fail? (bound/children e)))]
    (case (:node e)
      (:literal ::vec-literal :column :outer-column) false
      (:compare :and :or :not :is-null :between :concat :case :in-list :in-set :like) (kids-fail?)
      :cast (or (not (contains? #{[:int64 :float64] [:date :timestamp]}
                                [(t/kind (:type (:arg e))) (t/kind (:type e))]))
                (kids-fail?))
      :call (or (not (contains? #{"COALESCE" "CONCAT" "NULLIF" "LENGTH" "UPPER" "LOWER" "TRIM"
                                  "LTRIM" "RTRIM" "YEAR" "MONTH" "DAY" "HOUR" "MINUTE" "SECOND"}
                                (:fn e)))
                (kids-fail?))
      true)))

(defn- eval-right
  "Evaluates the right operand rk of a NULL-propagating binary operator
  whose left operand evaluated to lv: only on the rows where lv is not NULL
  if the operand may fail (the row engine does not evaluate it there)."
  ^polyquery.exec.batch.Vec [^Kernel rk may-fail ^Vec lv ^Batch bt ^ints sel n]
  (let [lnulls (when may-fail (nulls-of lv sel n))]
    (if lnulls
      (let [[sel2 n2] (non-null-sel lnulls sel n)]
        (if (zero? (long n2))
          (b/constant-vec :null nil)
          (ev rk bt sel2 n2)))
      (ev rk bt sel n))))

;; ---------------------------------------------------------------------------
;; Leaves and the row-closure fallback

(defn- bool-kernel
  "Kernel of a predicate operand: expressions of the NULL type (a bare NULL)
  are evaluated, then yield an all-NULL BoolVec."
  [env e]
  (let [k (compile-kernel env e)]
    (if-not (= :null (t/kind (:type e)))
      k
      (let [nul (b/constant-vec :boolean nil)]
        (reify Kernel (eval [_ bt sel n] (ev k bt sel n) nul))))))

(defn- literal-kernel [e]
  (let [cv (b/constant-vec (:type e) (:value e))]
    (reify Kernel (eval [_ _ _ _] cv))))

(defn- column-kernel [e]
  (let [idx (long (:index e)) type (:type e)]
    (reify Kernel (eval [_ bt _ _] (b/typed-column bt idx type)))))

(defn- row-kernel
  "Evaluates e with the row compiler, one selected row at a time. Rows are
  rebuilt from the batch columns e reads (all columns when e contains a
  subquery, whose correlated references may read any of them)."
  [env e]
  (let [f (expr/compile-expr env e)
        type (:type e)
        all? (some #(= :subquery (:node %)) (bound/nodes e))
        cols (int-array (sort (bound/column-indices e)))]
    (reify Kernel
      (eval [_ bt sel n]
        (let [^objects bcols (.-cols bt)
              width (alength bcols)
              ^ints cols (if all?
                           (int-array (filter #(some? (aget bcols %)) (range width)))
                           cols)
              ncols (alength cols)
              row (object-array width)
              out (b/new-vec type)]
          (each-sel [i sel n]
            (dotimes [c ncols]
              (let [ci (aget cols c)]
                (aset row ci (.getObj ^Vec (aget bcols ci) i))))
            (.setObj out i (f row)))
          out)))))

;; ---------------------------------------------------------------------------
;; Numeric conversions

(defn- as-doubles
  "double[] of a numeric vector of type t at the selected positions (the
  conversion of polyquery.values/->double-fn)."
  ^doubles [^Vec x t ^ints sel n]
  (case (t/kind t)
    :float64 (.-v ^DoubleVec x)
    :int64 (let [src ^longs (.-v ^LongVec x) out (double-array cap)]
             (each-sel [i sel n] (aset out i (double (aget src i))))
             out)
    :decimal (let [src ^longs (.-v ^LongVec x)
                   nulls ^booleans (.-nulls ^LongVec x)
                   s (t/scale t)
                   out (double-array cap)]
               (each-sel [i sel n]
                 (when-not (b/nulls-at? nulls i)
                   (aset out i (v/dec->double (aget src i) s))))
               out)
    :null (double-array cap)))

;; ---------------------------------------------------------------------------
;; Arithmetic

(defmacro ^:private long-op
  "LongVec of (expr a b) over two LongVecs, skipping NULL rows."
  [lv rv sel n [a c] body]
  `(let [lv# ~lv rv# ~rv sel# ~sel n# (long ~n)
         la# ^"[J" (.-v ^LongVec lv#)
         ra# ^"[J" (.-v ^LongVec rv#)
         nulls# (union-nulls (.-nulls ^LongVec lv#) (.-nulls ^LongVec rv#) sel# n#)
         out# (long-array cap)]
     (if nulls#
       (each-sel [i# sel# n#]
         (when-not (aget ^"[Z" nulls# i#)
           (let [~a (aget la# i#) ~c (aget ra# i#)] (aset out# i# (long ~body)))))
       (each-sel [i# sel# n#]
         (let [~a (aget la# i#) ~c (aget ra# i#)] (aset out# i# (long ~body)))))
     (LongVec. out# nulls#)))

;; one function per operator keeps every method small enough for the JIT

(defn- add-longs [lv rv sel n]
  (long-op lv rv sel n [a c] (let [r (unchecked-add a c)]
                               (when (neg? (bit-and (bit-xor a r) (bit-xor c r))) (overflow!))
                               r)))

(defn- sub-longs [lv rv sel n]
  (long-op lv rv sel n [a c] (let [r (unchecked-subtract a c)]
                               (when (neg? (bit-and (bit-xor a c) (bit-xor a r))) (overflow!))
                               r)))

(defn- mul-longs [lv rv sel n]
  (long-op lv rv sel n [a c] (let [hi (Math/multiplyHigh a c)
                                   r (unchecked-multiply a c)]
                               (when-not (== hi (bit-shift-right r 63)) (overflow!))
                               r)))

(defn- div-longs [lv rv sel n]
  (long-op lv rv sel n [a c] (do (when (zero? c) (div-zero!))
                                 (when (and (== a Long/MIN_VALUE) (== c -1)) (overflow!))
                                 (quot a c))))

(defn- rem-longs [lv rv sel n]
  (long-op lv rv sel n [a c] (do (when (zero? c) (div-zero!))
                                 (rem a c))))

(defn- int-arith [op]
  (case op "+" add-longs "-" sub-longs "*" mul-longs "/" div-longs "%" rem-longs))

(defn- check-dec18 ^long [^long r]
  (when (or (> r v/max-unscaled) (< r (- v/max-unscaled)))
    (v/overflow! "decimal arithmetic"))
  r)

(defn- add-decimals [lv rv sel n]
  (long-op lv rv sel n [a c] (let [r (unchecked-add a c)]
                               (when (neg? (bit-and (bit-xor a r) (bit-xor c r)))
                                 (v/overflow! "decimal addition"))
                               (check-dec18 r))))

(defn- sub-decimals [lv rv sel n]
  (long-op lv rv sel n [a c] (let [r (unchecked-subtract a c)]
                               (when (neg? (bit-and (bit-xor a c) (bit-xor a r)))
                                 (v/overflow! "decimal addition"))
                               (check-dec18 r))))

(defn- add-rescaled [sl sr lv rv sel n]
  (let [sl (long sl) sr (long sr)]
    (long-op lv rv sel n [a c] (v/dec-add a sl c sr))))

(defn- sub-rescaled [sl sr lv rv sel n]
  (let [sl (long sl) sr (long sr)]
    (long-op lv rv sel n [a c] (v/dec-add a sl (- c) sr))))

(defn- mul-decimals [lv rv sel n]
  (long-op lv rv sel n [a c] (v/dec-mul a c)))

(defn- decimal-arith [op lt rt]
  (let [sl (t/scale lt) sr (t/scale rt)]
    (case op
      "+" (if (= sl sr) add-decimals (partial add-rescaled sl sr))
      "-" (if (= sl sr) sub-decimals (partial sub-rescaled sl sr))
      "*" mul-decimals)))

(defmacro ^:private double-op
  "DoubleVec of (body a b) over two double arrays, skipping NULL rows."
  [la ra nulls sel n [a c] body]
  `(let [la# ~la ra# ~ra nulls# ~nulls sel# ~sel n# (long ~n)
         out# (double-array cap)]
     (if nulls#
       (each-sel [i# sel# n#]
         (when-not (aget ^"[Z" nulls# i#)
           (let [~a (aget ^"[D" la# i#) ~c (aget ^"[D" ra# i#)] (aset out# i# (double ~body)))))
       (each-sel [i# sel# n#]
         (let [~a (aget ^"[D" la# i#) ~c (aget ^"[D" ra# i#)] (aset out# i# (double ~body)))))
     (DoubleVec. out# nulls#)))

(defn- finite ^double [^double d]
  (when (or (Double/isInfinite d) (Double/isNaN d)) (float-overflow!))
  d)

(defn- add-doubles [la ra nulls sel n] (double-op la ra nulls sel n [a c] (finite (+ a c))))
(defn- sub-doubles [la ra nulls sel n] (double-op la ra nulls sel n [a c] (finite (- a c))))
(defn- mul-doubles [la ra nulls sel n] (double-op la ra nulls sel n [a c] (finite (* a c))))
(defn- div-doubles [la ra nulls sel n] (double-op la ra nulls sel n [a c] (do (when (== c 0.0) (div-zero!))
                                                                              (finite (/ a c)))))

(defn- float-arith [op lt rt]
  (let [f (case op "+" add-doubles "-" sub-doubles "*" mul-doubles "/" div-doubles)]
    (fn [lv rv sel n]
      (f (as-doubles lv lt sel n) (as-doubles rv rt sel n)
         (union-nulls (nulls-of lv sel n) (nulls-of rv sel n) sel n) sel n))))

(defn- arith-kernel [env e]
  (let [{:keys [op type left right]} e
        lt (:type left) rt (:type right)
        lk (compile-kernel env left)
        rk (compile-kernel env right)
        fail? (may-fail? right)
        f (case (t/kind type)
            :int64 (int-arith op)
            :float64 (float-arith op lt rt)
            :decimal (decimal-arith op lt rt)
            nil)]
    (if (and f (not= :null (t/kind lt)) (not= :null (t/kind rt)))
      (reify Kernel
        (eval [_ bt sel n]
          (let [lv (ev lk bt sel n)
                rv (eval-right rk fail? lv bt sel n)]
            (if (instance? ObjVec rv)
              ;; the right operand was NULL on every evaluated row
              (b/constant-vec type nil)
              (f lv rv sel n)))))
      (row-kernel env e))))

(defn- neg-kernel [env e]
  (let [ak (compile-kernel env (:arg e))]
    (case (t/kind (:type e))
      (:int64 :decimal)
      (let [int? (= :int64 (t/kind (:type e)))]
        (reify Kernel
          (eval [_ bt sel n]
            (let [x ^LongVec (ev ak bt sel n)
                  src ^longs (.-v x)
                  nulls ^booleans (.-nulls x)
                  out (long-array cap)]
              (each-sel [i sel n]
                (when-not (b/nulls-at? nulls i)
                  (let [a (aget src i)]
                    (when (and int? (== a Long/MIN_VALUE)) (overflow!))
                    (aset out i (- a)))))
              (LongVec. out nulls)))))
      :float64
      (reify Kernel
        (eval [_ bt sel n]
          (let [x ^DoubleVec (ev ak bt sel n)
                src ^doubles (.-v x)
                out (double-array cap)]
            (each-sel [i sel n] (aset out i (- (aget src i))))
            (DoubleVec. out ^booleans (.-nulls x)))))
      (row-kernel env e))))

;; ---------------------------------------------------------------------------
;; Comparison

(defn- flip-op [op]
  (case op "<" ">" ">" "<" "<=" ">=" ">=" "<=" op))

(def ^:private op-tables
  "Per comparison operator, its result for a comparison outcome of -1, 0, 1
  (index outcome + 1): one branch-free loop serves every operator."
  (into {} (map (fn [[op v]] [op (boolean-array v)]))
        {"=" [false true false] "<>" [true false true] "<" [true false false]
         "<=" [true true false] ">" [false false true] ">=" [false true true]}))

(defmacro ^:private bool-loop
  "BoolVec of `op` applied to (cmp-expr i) (a negative/zero/positive long) at
  the selected positions; rows NULL in `nulls` are NULL (cmp-expr is not
  evaluated for them)."
  [op nulls sel n [i] cmp-expr]
  (let [tbl (with-meta (gensym "tbl") {:tag "[Z"})
        nl (with-meta (gensym "nulls") {:tag "[Z"})
        sl (gensym "sel") cnt (gensym "n")
        out (with-meta (gensym "out") {:tag "[Z"})]
    `(let [~tbl (op-tables ~op) ~nl ~nulls ~sl ~sel ~cnt (long ~n)
           ~out (boolean-array cap)]
       (if ~nl
         (each-sel [~i ~sl ~cnt]
           (when-not (aget ~nl ~i)
             (aset ~out ~i (aget ~tbl (inc (Long/signum (long ~cmp-expr)))))))
         (each-sel [~i ~sl ~cnt]
           (aset ~out ~i (aget ~tbl (inc (Long/signum (long ~cmp-expr)))))))
       (BoolVec. ~out ~nl))))

(defn- dec-cmp
  "Compares decimal a (scale sa) with c (scale sc); fast when the rescaled
  value fits a long."
  ^long [^long a ^long sa ^long c ^long sc]
  (v/dec-compare a sa c sc))

(defn- long-domain
  "long[] of a LongVec of type t converted for comparison type cmp-type
  (DATE → TIMESTAMP micros); nil when no conversion is needed."
  ^longs [^LongVec x t cmp-type ^ints sel n]
  (if (and (= :timestamp (t/kind cmp-type)) (= :date (t/kind t)))
    (let [src ^longs (.-v x) out (long-array cap)]
      (each-sel [i sel n] (aset out i (* (aget src i) v/micros-per-day)))
      out)
    (.-v x)))

(defn- compare-longs ^BoolVec [op ^longs la ^longs ra nulls sel n]
  (bool-loop op nulls sel n [i] (Long/compare (aget la i) (aget ra i))))

(defn- compare-decimals ^BoolVec [op ^longs la sl ^longs ra sr nulls sel n]
  (let [sl (long sl) sr (long sr)]
  (bool-loop op nulls sel n [i] (dec-cmp (aget la i) sl (aget ra i) sr))))

(defn- compare-doubles ^BoolVec [op ^doubles la ^doubles ra nulls sel n]
  (bool-loop op nulls sel n [i] (let [x (aget la i) y (aget ra i)]
                                  (cond (< x y) -1 (> x y) 1 :else 0))))

(defn- compare-booleans ^BoolVec [op ^booleans la ^booleans ra nulls sel n]
  (bool-loop op nulls sel n [i] (Boolean/compare (aget la i) (aget ra i))))

(defn- compare-strings ^BoolVec [op ^Vec lv ^Vec rv nulls sel n]
  (if (#{"=" "<>"} op)
    (bool-loop op nulls sel n [i] (if (.equals ^Object (.getObj lv i) (.getObj rv i)) 0 1))
    (bool-loop op nulls sel n [i] (text/compare-code-points (.getObj lv i) (.getObj rv i)))))

(defn compare-vecs
  "BoolVec of `lv op rv` for the selected positions, operands of types lt
  and rt compared in cmp-type (the semantics of polyquery.values/comparator-fn)."
  ^BoolVec [op cmp-type lt rt ^Vec lv ^Vec rv ^ints sel n]
  (let [n (long n)
        nulls (union-nulls (nulls-of lv sel n) (nulls-of rv sel n) sel n)]
    (case (t/kind cmp-type)
      (:int64 :date :timestamp)
      (compare-longs op (long-domain lv lt cmp-type sel n) (long-domain rv rt cmp-type sel n) nulls sel n)

      :decimal
      (let [sl (t/scale lt) sr (t/scale rt)]
        (if (= sl sr)
          (compare-longs op (.-v ^LongVec lv) (.-v ^LongVec rv) nulls sel n)
          (compare-decimals op (.-v ^LongVec lv) sl (.-v ^LongVec rv) sr nulls sel n)))

      :float64
      (compare-doubles op (as-doubles lv lt sel n) (as-doubles rv rt sel n) nulls sel n)

      :boolean
      (compare-booleans op (.-v ^BoolVec lv) (.-v ^BoolVec rv) nulls sel n)

      :string (compare-strings op lv rv nulls sel n)

      :null (b/constant-vec :boolean nil))))

(defn- dict-matches
  "Per-dictionary cache of (test code) results: boolean[] over the codes of
  a dictionary, computed on first use of that dictionary."
  [test]
  (let [cache (IdentityHashMap.)]
    (fn ^booleans [^objects dict]
      (locking cache
        (or (.get cache dict)
            (let [out (boolean-array (alength dict))]
              (dotimes [c (alength dict)] (aset out c (boolean (test (aget dict c)))))
              (.put cache dict out)
              out))))))

(defn- string-test-kernel
  "BoolVec kernel of (test s) for a STRING-valued kernel xk (NULL → NULL);
  dictionary vectors evaluate test once per dictionary entry."
  [xk test]
  (let [per-dict (dict-matches test)]
    (reify Kernel
      (eval [_ bt sel n]
        (let [x (ev xk bt sel n)
              out (boolean-array cap)]
          (if (instance? DictVec x)
            (let [^DictVec d x
                  codes ^ints (.-codes d)
                  ^booleans m (per-dict (.-dict d))
                  nulls ^booleans (.-nulls d)]
              (each-sel [i sel n]
                (when-not (b/nulls-at? nulls i) (aset out i (aget m (aget codes i)))))
              (BoolVec. out nulls))
            (let [nulls (nulls-of x sel n)]
              (each-sel [i sel n]
                (let [s (.getObj x i)]
                  (when (some? s) (aset out i (boolean (test s))))))
              (BoolVec. out nulls))))))))

(defmacro ^:private op-loops
  "One plain loop per operator over positions 0..n-1 storing (op lhs rhs):
  straight-line array code that C2 compiles to SIMD instructions."
  [code n [i] lhs rhs out]
  `(case (int ~code)
     0 (dotimes [~i ~n] (aset ~out ~i (== ~lhs ~rhs)))
     1 (dotimes [~i ~n] (aset ~out ~i (not (== ~lhs ~rhs))))
     2 (dotimes [~i ~n] (aset ~out ~i (< ~lhs ~rhs)))
     3 (dotimes [~i ~n] (aset ~out ~i (<= ~lhs ~rhs)))
     4 (dotimes [~i ~n] (aset ~out ~i (> ~lhs ~rhs)))
     5 (dotimes [~i ~n] (aset ~out ~i (>= ~lhs ~rhs)))))

(def ^:private op-codes {"=" 0 "<>" 1 "<" 2 "<=" 3 ">" 4 ">=" 5})

(defn- compare-long-const
  "BoolVec of `x op c` for long values xa (identity selection fast path)."
  [op ^longs xa c ^booleans nulls ^ints sel n]
  (let [c (long c) n (long n)]
    (if (and (nil? nulls) (identical? sel b/identity-sel))
      (let [out (boolean-array cap)]
        (op-loops (op-codes op) n [i] (aget xa i) c out)
        (BoolVec. out nil))
      (bool-loop op nulls sel n [i] (Long/compare (aget xa i) c)))))

(defn- compare-double-const
  "BoolVec of `x op d` for double values xa (identity selection fast path)."
  [op ^doubles xa d ^booleans nulls ^ints sel n]
  (let [d (double d) n (long n)]
    (if (and (nil? nulls) (identical? sel b/identity-sel))
      (let [out (boolean-array cap)]
        (op-loops (op-codes op) n [i] (aget xa i) d out)
        (BoolVec. out nil))
      (bool-loop op nulls sel n [i] (let [y (aget xa i)] (cond (< y d) -1 (> y d) 1 :else 0))))))

(defn- const-compare-kernel
  "Kernel of `x op c` for a constant non-NULL c of type ct (x of type xt)."
  [env op cmp-type xe xt c ct]
  (let [xk (compile-kernel env xe)
        k (t/kind cmp-type)]
    (cond
      (and (#{:int64 :date :timestamp} k) (= (t/kind ct) k) (= (t/kind xt) k))
      ;; long column against a long constant of the comparison domain
      (let [c (long c)]
        (reify Kernel
          (eval [_ bt sel n]
            (let [x ^LongVec (ev xk bt sel n)]
              (compare-long-const op (.-v x) c (.-nulls x) sel n)))))

      (and (= :decimal k) (= :decimal (t/kind xt)) (<= (t/scale ct) (t/scale xt))
           (not-any? t/wide? [cmp-type xt ct])
           (instance? Long (v/dec-rescale-up (long c) (- (t/scale xt) (t/scale ct)))))
      ;; constant rescaled to the column's scale
      (let [c (long (v/dec-rescale-up (long c) (- (t/scale xt) (t/scale ct))))]
        (reify Kernel
          (eval [_ bt sel n]
            (let [x ^LongVec (ev xk bt sel n)]
              (compare-long-const op (.-v x) c (.-nulls x) sel n)))))

      (and (= :float64 k) (#{:float64 :int64} (t/kind xt)))
      (let [d (double ((v/->double-fn ct) c))]
        (reify Kernel
          (eval [_ bt sel n]
            (let [x (ev xk bt sel n)]
              (compare-double-const op (as-doubles x xt sel n) d (nulls-of x sel n) sel n)))))

      (= :string k)
      (let [^String c c
            test (case op
                   "=" #(.equals c %)
                   "<>" #(not (.equals c %))
                   (let [tst (case op "<" neg? "<=" (complement pos?) ">" pos? ">=" (complement neg?))]
                     #(tst (text/compare-code-points % c))))]
        (string-test-kernel xk test))

      :else nil)))

(defn- compare-kernel [env e]
  (let [{:keys [op cmp-type left right]} e
        lt (:type left) rt (:type right)
        const? (fn [x] (and (= :literal (:node x)) (some? (:value x))))]
    (cond
      (= :null (t/kind cmp-type)) (literal-kernel {:type :boolean :value nil})
      (or (= :null (t/kind lt)) (= :null (t/kind rt))) (row-kernel env e)

      (and (const? right) (not (const? left)))
      (or (const-compare-kernel env op cmp-type left lt (:value right) rt)
          (compare-kernel env (assoc e :right (assoc right :node ::vec-literal))))

      (and (const? left) (not (const? right)))
      (or (const-compare-kernel env (flip-op op) cmp-type right rt (:value left) lt)
          (compare-kernel env (assoc e :left (assoc left :node ::vec-literal))))

      :else
      (let [lk (compile-kernel env left)
            rk (compile-kernel env right)
            fail? (may-fail? right)]
        (reify Kernel
          (eval [_ bt sel n]
            (let [lv (ev lk bt sel n)
                  rv (eval-right rk fail? lv bt sel n)]
              (if (and (instance? ObjVec rv) (not= :string (t/kind cmp-type)))
                (b/constant-vec :boolean nil)
                (compare-vecs op cmp-type lt rt lv rv sel n)))))))))

;; ---------------------------------------------------------------------------
;; Boolean logic

(defn- logic-kernel
  "AND (and? true) / OR: the right operand is only evaluated where the left
  one does not decide the result."
  [env e and?]
  (let [lk (bool-kernel env (:left e))
        rk (bool-kernel env (:right e))
        decided (not and?)]
    (reify Kernel
      (eval [_ bt sel n]
        (let [l ^BoolVec (ev lk bt sel n)
              lv ^booleans (.-v l)
              ln ^booleans (.-nulls l)
              ;; rows where the left operand does not decide
              [sel2 n2] (b/positions-where sel n (fn [^long i] (or (b/nulls-at? ln i)
                                                                   (not= decided (aget lv i)))))
              n2 (long n2)]
          (if (zero? n2)
            l
            (let [r ^BoolVec (ev rk bt sel2 n2)
                  rv ^booleans (.-v r)
                  rn ^booleans (.-nulls r)
                  out (boolean-array cap)
                  nulls (boolean-array cap)]
              (each-sel [i sel n] (aset out i (aget lv i)))
              (when ln (each-sel [i sel n] (aset nulls i (aget ln i))))
              (each-sel [i sel2 n2]
                (let [lnull (b/nulls-at? ln i)
                      rnull (b/nulls-at? rn i)
                      rval (aget rv i)]
                  (cond
                    (and (not rnull) (= decided rval)) (do (aset out i decided) (aset nulls i false))
                    (or lnull rnull) (aset nulls i true)
                    :else (do (aset out i (not decided)) (aset nulls i false)))))
              (BoolVec. out nulls))))))))

(defn- not-kernel [env e]
  (let [ak (bool-kernel env (:arg e))]
    (reify Kernel
      (eval [_ bt sel n]
        (let [x ^BoolVec (ev ak bt sel n)
              src ^booleans (.-v x)
              out (boolean-array cap)]
          (each-sel [i sel n] (aset out i (not (aget src i))))
          (BoolVec. out ^booleans (.-nulls x)))))))

(defn- is-null-kernel [env e]
  (let [ak (compile-kernel env (:arg e))
        not? (boolean (:not? e))]
    (reify Kernel
      (eval [_ bt sel n]
        (let [x (ev ak bt sel n)
              nulls (nulls-of x sel n)
              out (boolean-array cap)]
          (cond
            nulls (each-sel [i sel n] (aset out i (not= not? (aget nulls i))))
            not? (each-sel [i sel n] (aset out i true)))
          (BoolVec. out nil))))))

(defn- and3-vecs
  "Three-valued AND of two BoolVecs (both fully evaluated)."
  ^BoolVec [^BoolVec x ^BoolVec y ^ints sel ^long n]
  (let [xv ^booleans (.-v x) xn ^booleans (.-nulls x)
        yv ^booleans (.-v y) yn ^booleans (.-nulls y)
        out (boolean-array cap)
        nulls (when (or xn yn) (boolean-array cap))]
    (each-sel [i sel n]
      (let [xnull (b/nulls-at? xn i) ynull (b/nulls-at? yn i)
            a (aget xv i) c (aget yv i)]
        (cond
          (or (and (not xnull) (not a)) (and (not ynull) (not c))) nil
          (or xnull ynull) (aset ^booleans nulls i true)
          :else (aset out i true))))
    (BoolVec. out nulls)))

(defn- not-vec ^BoolVec [^BoolVec x ^ints sel ^long n]
  (let [src ^booleans (.-v x) out (boolean-array cap)]
    (each-sel [i sel n] (aset out i (not (aget src i))))
    (BoolVec. out ^booleans (.-nulls x))))

(defn- between-kernel [env e]
  ;; x, low and high are evaluated on every row, as in the row engine
  (let [xe (:arg e)
        xk (compile-kernel env xe)
        lk (compile-kernel env (:low e))
        hk (compile-kernel env (:high e))
        xt (:type xe)
        not? (:not? e)]
    (reify Kernel
      (eval [_ bt sel n]
        (let [x (ev xk bt sel n)
              lo (ev lk bt sel n)
              hi (ev hk bt sel n)
              cmp (fn [op cmp-type yt y]
                    (if (or (= :null (t/kind cmp-type)) (= :null (t/kind yt)) (= :null (t/kind xt)))
                      (b/constant-vec :boolean nil)
                      (compare-vecs op cmp-type xt yt x y sel n)))
              r (and3-vecs (cmp ">=" (:low-type e) (:type (:low e)) lo)
                           (cmp "<=" (:high-type e) (:type (:high e)) hi)
                           sel n)]
          (if not? (not-vec r sel n) r))))))

;; ---------------------------------------------------------------------------
;; IN lists, LIKE

(defn- in-list-kernel [env e]
  (let [{:keys [items cmp-types not?]} e
        xe (:arg e)
        xt (:type xe)
        ct (first cmp-types)]
    (if (and (every? #(= :literal (:node %)) items)
             (apply = cmp-types)
             (not= :null (t/kind ct)))
      (let [has-null? (boolean (some #(nil? (:value %)) items))
            keys (HashSet.)
            _ (doseq [item items :when (some? (:value item))]
                (.add keys ((v/key-fn (:type item) ct) (:value item))))
            xkey (v/key-fn xt ct)
            ;; result for a non-NULL x: true, or NULL (nil) / false when absent
            absent (if has-null? nil false)
            result (fn [x] (let [r (if (.contains keys (xkey x)) true absent)]
                             (if (and not? (some? r)) (not r) r)))
            xk (compile-kernel env xe)]
        (if (= :string (t/kind xt))
          (if has-null?
            (row-kernel env e)
            (string-test-kernel xk result))
          (reify Kernel
            (eval [_ bt sel n]
              (let [x (ev xk bt sel n)
                    out (b/new-vec :boolean)]
                (each-sel [i sel n]
                  (let [xv (.getObj x i)]
                    (.setObj out i (when (some? xv) (result xv)))))
                out)))))
      (row-kernel env e))))

(defn- in-set-kernel [env e]
  (let [test (expr/in-set-fn e)
        xk (compile-kernel env (:arg e))]
    (if (and (= :string (t/kind (:type (:arg e))))
             (not (:has-null? e))
             (not (:exists? e))
             (not (.isEmpty ^java.util.Set (:keys e))))
      ;; NULL → NULL, else TRUE/FALSE
      (string-test-kernel xk test)
      (reify Kernel
        (eval [_ bt sel n]
          (let [x (ev xk bt sel n)
                out (b/new-vec :boolean)]
            (each-sel [i sel n]
              (.setObj out i (test (.getObj x i))))
            out))))))

(defn- like-kernel [env e]
  (let [pat (:pattern e)]
    (if (= :literal (:node pat))
      (let [xk (compile-kernel env (:arg e))
            not? (boolean (:not? e))]
        (if-let [m (when (some? (:value pat)) (functions/like-matcher (:value pat)))]
          (string-test-kernel xk (fn [s] (not= not? (boolean (m s)))))
          (literal-kernel {:type :boolean :value nil})))
      (row-kernel env e))))

;; ---------------------------------------------------------------------------
;; CAST

(defn- unary-kernel
  "Kernel applying f to every non-NULL value of ak's vector (boxed), with a
  result of type `type`."
  [ak type f]
  (reify Kernel
    (eval [_ bt sel n]
      (let [x (ev ak bt sel n)
            out (b/new-vec type)]
        (each-sel [i sel n]
          (let [a (.getObj x i)]
            (.setObj out i (when (some? a) (f a)))))
        out))))

(defn- cast-kernel [env e]
  (let [from (:type (:arg e)) to (:type e)
        ak (compile-kernel env (:arg e))]
    (cond
      (= from to) ak
      (= :null (t/kind from)) (literal-kernel {:type to :value nil})

      (and (= :int64 (t/kind from)) (= :float64 (t/kind to)))
      (reify Kernel
        (eval [_ bt sel n]
          (let [x ^LongVec (ev ak bt sel n)
                src ^longs (.-v x) out (double-array cap)]
            (each-sel [i sel n] (aset out i (double (aget src i))))
            (DoubleVec. out ^booleans (.-nulls x)))))

      (and (= :date (t/kind from)) (= :timestamp (t/kind to)))
      (reify Kernel
        (eval [_ bt sel n]
          (let [x ^LongVec (ev ak bt sel n)
                src ^longs (.-v x) out (long-array cap)]
            (each-sel [i sel n] (aset out i (* (aget src i) v/micros-per-day)))
            (LongVec. out ^booleans (.-nulls x)))))

      (and (= :int64 (t/kind from)) (= :decimal (t/kind to)) (not (t/wide? to)))
      (let [p (t/precision to)
            f (long (v/dec-rescale-up 1 (t/scale to)))
            bound (long (v/dec-rescale-up 1 p))]
        (reify Kernel
          (eval [_ bt sel n]
            (let [x ^LongVec (ev ak bt sel n)
                  src ^longs (.-v x) nulls ^booleans (.-nulls x) out (long-array cap)]
              (each-sel [i sel n]
                (when-not (b/nulls-at? nulls i)
                  (let [a (aget src i)
                        hi (Math/multiplyHigh a f)
                        r (unchecked-multiply a f)]
                    (when (or (not (== hi (bit-shift-right r 63))) (>= r bound) (<= r (- bound)))
                      (v/overflow! (str "conversion to " (t/type-name to))))
                    (aset out i r))))
              (LongVec. out nulls)))))

      :else (unary-kernel ak to (v/cast-fn from to)))))

;; ---------------------------------------------------------------------------
;; CASE, COALESCE, function calls

(defn- copy-into!
  "Copies the selected values of src into the writable vector out."
  [^Vec out ^Vec src ^ints sel ^long n]
  (cond
    (and (instance? LongVec out) (instance? LongVec src))
    (let [o ^longs (.-v ^LongVec out) on ^booleans (.-nulls ^LongVec out)
          s ^longs (.-v ^LongVec src) sn ^booleans (.-nulls ^LongVec src)]
      (each-sel [i sel n] (aset o i (aget s i)) (aset on i (b/nulls-at? sn i))))
    (and (instance? DoubleVec out) (instance? DoubleVec src))
    (let [o ^doubles (.-v ^DoubleVec out) on ^booleans (.-nulls ^DoubleVec out)
          s ^doubles (.-v ^DoubleVec src) sn ^booleans (.-nulls ^DoubleVec src)]
      (each-sel [i sel n] (aset o i (aget s i)) (aset on i (b/nulls-at? sn i))))
    :else (each-sel [i sel n] (.setObj out i (.getObj src i)))))

(defn- fill-null!
  [^Vec out ^ints sel ^long n]
  (each-sel [i sel n] (.setObj out i nil)))

(defn- case-kernel [env e]
  (let [whens (mapv (fn [[w r]] [(bool-kernel env w) (compile-kernel env r)]) (:whens e))
        else-k (when (:else e) (compile-kernel env (:else e)))
        type (:type e)]
    (reify Kernel
      (eval [_ bt sel n]
        (let [out (b/new-vec type)]
          (loop [ws whens ^ints sel sel n n]
            (if (zero? (long n))
              out
              (if-let [[wk rk] (first ws)]
                (let [c ^BoolVec (ev wk bt sel n)
                      [tsel tn] (b/true-positions c sel n)
                      [rsel rn] (b/positions-where sel n (let [cv ^booleans (.-v c) cn ^booleans (.-nulls c)]
                                                           (fn [^long i] (or (b/nulls-at? cn i)
                                                                             (not (aget cv i))))))]
                  (when (pos? (long tn))
                    (copy-into! out (ev rk bt tsel tn) tsel tn))
                  (recur (rest ws) rsel (long rn)))
                (do (if else-k
                      (copy-into! out (ev else-k bt sel n) sel n)
                      (fill-null! out sel n))
                    out)))))))))

(defn- coalesce-kernel [env e]
  (let [ks (mapv #(compile-kernel env %) (:args e))
        type (:type e)]
    (reify Kernel
      (eval [_ bt sel n]
        (let [out (b/new-vec type)]
          (loop [ks ks ^ints sel sel n n]
            (cond
              (zero? (long n)) out
              (empty? ks) (do (fill-null! out sel n) out)
              :else (let [x (ev (first ks) bt sel n)]
                      (copy-into! out x sel n)
                      (let [nulls (nulls-of x sel n)]
                        (if nulls
                          (let [[s2 n2] (b/positions-where sel n (fn [^long i] (aget ^booleans nulls i)))]
                            (recur (rest ks) s2 (long n2)))
                          out))))))))))

(defn- call-kernel
  "Function calls whose arguments cannot fail: the arguments are evaluated
  as vectors and the row engine's function is applied per row to them."
  [env e]
  (if (or (some may-fail? (:args e)) (= "PQ_SLEEP" (:fn e)))
    (row-kernel env e)
    (let [ks (into-array Kernel (map #(compile-kernel env %) (:args e)))
          nargs (alength ^objects ks)
          ^objects current (object-array (max 1 nargs))
          arg-fns (mapv (fn [j] (fn [_] (aget current j))) (range nargs))
          f (functions/compile-call e arg-fns (:ctx env))
          type (:type e)]
      ;; `current` is shared by the closures above: one evaluation at a time
      (reify Kernel
        (eval [_ bt sel n]
          (locking current
            (let [args (object-array nargs)
                  out (b/new-vec type)]
              (dotimes [j nargs] (aset args j (ev (aget ^objects ks j) bt sel n)))
              (each-sel [i sel n]
                (dotimes [j nargs] (aset current j (.getObj ^Vec (aget args j) i)))
                (.setObj out i (f nil)))
              out)))))))

;; ---------------------------------------------------------------------------

(defn- concat-kernel
  "`a || b`: NULL-propagating string concatenation."
  [env e]
  (let [lk (compile-kernel env (:left e))
        rk (compile-kernel env (:right e))
        fail? (may-fail? (:right e))]
    (reify Kernel
      (eval [_ bt sel n]
        (let [lv (ev lk bt sel n)
              rv (eval-right rk fail? lv bt sel n)
              out (object-array cap)]
          (each-sel [i sel n]
            (let [a (.getObj lv i)]
              (when (some? a)
                (let [c (.getObj rv i)]
                  (when (some? c) (aset out i (str a c)))))))
          (ObjVec. out))))))

(defn- wide-operands?
  "True when arithmetic or a comparison node e computes on wide DECIMAL
  values, which the primitive kernels do not handle."
  [e]
  (boolean (some t/wide? (concat [(:type e) (:cmp-type e) (:low-type e) (:high-type e)]
                                 (map :type (bound/children e))))))

(defn compile-kernel
  "Compiles bound expression e into a Kernel. env is the row compiler's
  environment (polyquery.exec.expr)."
  ^Kernel [env e]
  (case (:node e)
    :literal (literal-kernel e)
    ::vec-literal (literal-kernel e)
    :column (column-kernel e)
    (:arith :neg :compare :between)
    (if (wide-operands? e)
      (row-kernel env e)
      (case (:node e)
        :arith (arith-kernel env e)
        :neg (neg-kernel env e)
        :compare (compare-kernel env e)
        :between (between-kernel env e)))
    :and (logic-kernel env e true)
    :or (logic-kernel env e false)
    :not (not-kernel env e)
    :is-null (is-null-kernel env e)
    :in-list (in-list-kernel env e)
    :in-set (in-set-kernel env e)
    :like (like-kernel env e)
    :cast (cast-kernel env e)
    :case (case-kernel env e)
    :call (if (= "COALESCE" (:fn e)) (coalesce-kernel env e) (call-kernel env e))
    :concat (concat-kernel env e)
    (row-kernel env e)))

(defn compile-filter
  "Compiles a predicate into (fn [batch]) → [sel n] of the rows where it is
  TRUE."
  [env e]
  (let [k (bool-kernel env e)]
    (fn [^Batch bt]
      (b/true-positions (ev k bt (.-sel bt) (.-n bt)) (.-sel bt) (.-n bt)))))
