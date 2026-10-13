(ns polyquery.sql.binder
  "Expression binding: name resolution of column references against scopes
  (including enclosing queries' scopes for correlated subqueries), typing and
  coercion rules, aggregate validation and GROUP BY matching
  (spec/sql/semantics.md, spec/data-types/types.md). Turns AST expressions
  (polyquery.sql.ast) into bound expressions (polyquery.sql.bound).

  Scopes are vectors of range variables {:name alias :columns [{:name :type
  :index}]}, where :index is the position of the column in the row the
  expression is evaluated on.

  The binding context `cx` is the query analysis environment (see
  polyquery.sql.analyzer) extended with:
    :scope       input scope (vector of range variables, possibly empty)
    :mode        :plain    — plain row expression; aggregates rejected
                 :post-agg — expression over the aggregation output
                 :in-agg   — inside an aggregate argument
    :agg-error   message used when an aggregate appears in :plain mode
    :aggs        volatile vector of aggregate specs (post-agg mode)
    :group-keys  bound GROUP BY expressions (post-agg mode)
    :memo        memo tables of GROUP BY matching (post-agg mode; see
                 post-agg-context)

  Constant arguments (ROUND digits, DATE_TRUNC/DATE_DIFF units) are folded
  during validation with the expression compiler (polyquery.exec.expr)."
  (:require [clojure.string :as str]
            [polyquery.errors :as err]
            [polyquery.exec.context :as ctx]
            [polyquery.exec.expr :as expr]
            [polyquery.sql.ast :as ast]
            [polyquery.sql.bound :as b]
            [polyquery.sql.functions :as functions]
            [polyquery.types :as t]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.math BigInteger)
           (java.util IdentityHashMap)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Errors

(defn details [pos] (when pos {"line" (:line pos) "column" (:col pos)}))

(defn semantic! [msg pos] (err/fail! "SEMANTIC_ERROR" msg (details pos)))
(defn type-error! [msg pos] (err/fail! "TYPE_ERROR" msg (details pos)))

;; ---------------------------------------------------------------------------
;; Scopes

(defn same-name? [a b] (= (text/ascii-lower a) (text/ascii-lower b)))

(defn find-range-var [scope qualifier]
  (first (filter #(same-name? qualifier (:name %)) scope)))

(defn- matching-columns [rv cname]
  (filter #(same-name? cname (:name %)) (:columns rv)))

(defn lookup-column
  "Resolves a column reference against one scope. Returns the scope column,
  or nil when the scope has no candidate (unknown qualifier / no column of
  that name). Throws SEMANTIC_ERROR for ambiguous references and for unknown
  columns of a range variable that exists in the scope."
  [scope {:keys [table name pos]}]
  (if table
    (when-let [rv (find-range-var scope table)]
      (let [cols (matching-columns rv name)]
        (case (count cols)
          0 (semantic! (str "unknown column '" table "." name "'") pos)
          1 (first cols)
          (semantic! (str "ambiguous column '" table "." name "'") pos))))
    (let [cols (mapcat #(matching-columns % name) scope)]
      (case (count cols)
        0 nil
        1 (first cols)
        (semantic! (str "ambiguous column '" name "'") pos)))))

;; ---------------------------------------------------------------------------
;; Literals

(defn bind-number-literal
  [^String text pos]
  (let [neg? (str/starts-with? text "-")
        body (if neg? (subs text 1) text)]
    (cond
      (re-find #"[eE]" body)
      (let [d (Double/parseDouble text)]
        (when (Double/isInfinite d)
          (err/fail! "NUMERIC_OVERFLOW" (str "numeric literal out of range: " text) (details pos)))
        {:node :literal :type :float64 :value d})

      (str/includes? body ".")
      (let [dot (str/index-of body ".")
            ip (str/replace (subs body 0 dot) #"^0+" "")
            fp (subs body (inc dot))
            s (count fp)
            p (max (+ (count ip) s) s 1)]
        (if (> p t/max-decimal-precision)
          {:node :literal :type :float64 :value (Double/parseDouble text)}
          (let [digits (str ip fp)
                u (if (empty? digits) BigInteger/ZERO (BigInteger. digits))]
            {:node :literal :type (t/decimal p s) :value (v/dec-value (if neg? (.negate u) u) p)})))

      :else
      (try {:node :literal :type :int64 :value (Long/parseLong text)}
           (catch NumberFormatException _
             (err/fail! "NUMERIC_OVERFLOW" (str "integer literal out of range: " text) (details pos)))))))

(defn- bind-literal [e]
  (case (:kind e)
    :number (bind-number-literal (:text e) (:pos e))
    :string {:node :literal :type :string :value (:value e)}
    :bool {:node :literal :type :boolean :value (:value e)}
    :null {:node :literal :type :null :value nil}
    :date (if-let [d (v/parse-date (:value e))]
            {:node :literal :type :date :value d}
            (err/fail! "CONVERSION_ERROR" (str "invalid DATE literal '" (:value e) "'") (details (:pos e))))
    :timestamp (if-let [ts (v/parse-timestamp (:value e))]
                 {:node :literal :type :timestamp :value ts}
                 (err/fail! "CONVERSION_ERROR" (str "invalid TIMESTAMP literal '" (:value e) "'")
                            (details (:pos e))))))

(defn eval-constant
  "Evaluates a constant bound expression (constant folding at validation)."
  [e]
  (expr/eval-constant {:ctx (ctx/make-context {})} e))

;; ---------------------------------------------------------------------------
;; Typing rules

(defn- arith-type
  [op lt rt pos]
  (let [lt' (if (= lt :null) rt lt)
        rt' (if (= rt :null) lt rt)
        bad #(type-error! (str "operator " op " cannot be applied to " (t/describe lt) " and "
                               (t/describe rt)) pos)]
    (cond
      (and (= lt' :null) (= rt' :null)) :null
      (not (and (t/numeric? lt') (t/numeric? rt'))) (bad)
      :else
      (let [kl (t/kind lt') kr (t/kind rt')]
        (cond
          (or (= kl :float64) (= kr :float64)) (if (= op "%") (bad) :float64)
          (and (= kl :int64) (= kr :int64)) :int64
          :else (case op
                  ;; result precision W (decimal38.md §2)
                  ("+" "-") (t/decimal (t/result-precision lt' rt') (max (t/scale lt') (t/scale rt')))
                  "*" (let [s (+ (t/scale lt') (t/scale rt'))
                            w (t/result-precision lt' rt')]
                        (when (> s w)
                          (type-error! (str "DECIMAL multiplication result scale " s " exceeds " w) pos))
                        (t/decimal w s))
                  "/" :float64
                  "%" (bad)))))))

(defn check-boolean! [e what pos]
  (when-not (#{:boolean :null} (:type e))
    (type-error! (str what " must be BOOLEAN, got " (t/describe (:type e))) pos))
  e)

(defn- check-comparable! [l r pos]
  (when-not (t/comparable? (:type l) (:type r))
    (type-error! (str "cannot compare " (t/describe (:type l)) " with " (t/describe (:type r))) pos)))

(defn- compare-node [op l r pos]
  (check-comparable! l r pos)
  {:node :compare :op op :type :boolean :cmp-type (t/comparison-type (:type l) (:type r))
   :left l :right r})

;; ---------------------------------------------------------------------------
;; Expression binding

(declare bind)

(defn- bind-aggregate
  [cx e]
  (let [pos (:pos e)
        fname (text/ascii-upper (:name e))
        args (:args e)]
    (case (:mode cx)
      :plain (semantic! (or (:agg-error cx) (str "aggregate " fname " is not allowed here")) pos)
      :in-agg (semantic! "aggregate calls cannot be nested" pos)
      :post-agg nil)
    (when (and (:star? e) (not= fname "COUNT"))
      (semantic! (str fname "(*) is not allowed") pos))
    (when (and (not (:star? e)) (not= 1 (count args)))
      (semantic! (str fname " expects exactly one argument") pos))
    (let [arg (when-not (:star? e) (bind (assoc cx :mode :in-agg) (first args)))
          at (:type arg)
          spec (case fname
                 "COUNT" (if (:star? e)
                           {:fn :count-star :type :int64}
                           {:fn :count :arg arg :type :int64})
                 "SUM" (do (when-not (or (= at :null) (t/numeric? at))
                             (type-error! (str "SUM requires a numeric argument, got " (t/describe at)) pos))
                           {:fn :sum :arg arg
                            :type (case (t/kind at)
                                    :decimal (t/decimal (t/result-precision at) (t/scale at))
                                    :null :null
                                    at)})
                 "AVG" (do (when-not (or (= at :null) (t/numeric? at))
                             (type-error! (str "AVG requires a numeric argument, got " (t/describe at)) pos))
                           {:fn :avg :arg arg :type :float64})
                 "MIN" {:fn :min :arg arg :type at}
                 "MAX" {:fn :max :arg arg :type at})
          spec (assoc spec :distinct? (boolean (and (:distinct? e) (not (:star? e)))))
          aggs (:aggs cx)
          index (:agg-index (:memo cx))
          idx (or (get @index spec)
                  (do (vswap! aggs conj spec)
                      (let [i (dec (count @aggs))] (vswap! index assoc spec i) i)))]
      (b/column-ref (+ (count (:group-keys cx)) idx) (:type spec) (str "agg" idx)))))

(defn post-agg-context
  "The binding context of the expressions over the aggregation output of a
  query: base context `base` (its input scope), aggregate collector `aggs`
  and the bound GROUP BY keys.

  Every node of such an expression is matched against the GROUP BY keys,
  which binds it as a plain expression. The memo tables (keyed by AST node
  identity) keep each node's plain binding and AST properties, so matching
  costs time linear in the size of the expression, not quadratic. Equal
  aggregate calls share one aggregate, found through a hash index."
  [base aggs group-keys]
  (assoc base :mode :post-agg :aggs aggs :group-keys group-keys
         :memo {:plain (IdentityHashMap.) :flags (IdentityHashMap.) :agg-index (volatile! {})}))

(defn- ast-flags
  "{:aggregate? :subquery?} of AST expression e (ast/contains-aggregate?,
  ast/contains-subquery?), memoized."
  [^IdentityHashMap memo e]
  (or (.get memo e)
      (let [cs (mapv #(ast-flags memo %) (ast/children e))
            f {:aggregate? (or (ast/aggregate-call? e) (boolean (some :aggregate? cs)))
               :subquery? (or (contains? #{:in-query :exists :subquery} (:node e))
                              (boolean (some :subquery? cs)))}]
        (.put memo e f)
        f)))

(defn- group-key-ref
  "In post-agg mode: a reference to the GROUP BY key structurally equal to
  aggregate-free expression e, or nil."
  [cx e]
  (when (and (seq (:group-keys cx))
             (not= :literal (:node e))
             (let [{:keys [aggregate? subquery?]} (ast-flags (:flags (:memo cx)) e)]
               (not (or aggregate? subquery?))))
    (let [bound (try (bind (assoc cx :mode :plain) e)
                     (catch clojure.lang.ExceptionInfo _ nil))]
      (when bound
        (first (keep-indexed (fn [i g]
                               ;; hashes are cached: cheap pre-check
                               (when (and (= (hash g) (hash bound)) (= g bound))
                                 (b/column-ref i (:type g) (if (= :column (:node g)) (:name g) (str "key" i)))))
                             (:group-keys cx)))))))

(defn- frame-index
  "Index of scope column `col` of frame f in the row the frame's expressions
  are evaluated on."
  [f col e]
  (if (= :post-agg (:mode f))
    (or (first (keep-indexed (fn [i g] (when (and (= :column (:node g)) (= (:index g) (:index col))) i))
                             (:group-keys f)))
        (semantic! (str "column '" (:name e) "' must appear in GROUP BY or be used in an aggregate function")
                   (:pos e)))
    (:index col)))

(defn- outer-ref
  "Resolves e against the enclosing queries' frames (correlation), marking
  every query between the reference and the frame as correlated."
  [cx e]
  (loop [frames (:outer cx) k 0]
    (when-let [f (first frames)]
      (if-let [col (lookup-column (:scope f) e)]
        (let [index (frame-index f col e)
              cell (:cell f)]
          (doseq [fv (concat (:free cx) (mapcat :free (take k (:outer cx))))]
            (vswap! fv conj cell))
          {:node :outer-column :type (:type col) :cell cell :index index :name (:name col)})
        (recur (rest frames) (inc k))))))

(defn- bind-scope-column [cx col e]
  (when (= :post-agg (:mode cx))
    (semantic! (str "column '" (:name col) "' must appear in GROUP BY or be used in an aggregate function")
               (:pos e)))
  (b/column-ref (:index col) (:type col) (:name col)))

(defn- bind-column [cx e]
  (if-let [col (lookup-column (:scope cx) e)]
    (bind-scope-column cx col e)
    (or (outer-ref cx e)
        (if (:table e)
          (semantic! (str "unknown table or alias '" (:table e) "'") (:pos e))
          (semantic! (str "unknown column '" (:name e) "'") (:pos e))))))

(defn- bind-binary [cx e]
  (let [op (:op e)
        pos (:pos e)
        l (bind cx (:left e))
        r (bind cx (:right e))
        lt (:type l) rt (:type r)]
    (case op
      ("+" "-" "*" "/" "%")
      {:node :arith :op op :type (arith-type op lt rt pos) :left l :right r}

      "||"
      (do (when-not (and (#{:string :null} lt) (#{:string :null} rt))
            (type-error! (str "operator || requires STRING operands, got " (t/describe lt) " and "
                              (t/describe rt)) pos))
          {:node :concat :type :string :left l :right r})

      ("=" "<>" "<" "<=" ">" ">=")
      (compare-node op l r pos)

      ("AND" "OR")
      (do (check-boolean! l (str "operand of " op) pos)
          (check-boolean! r (str "operand of " op) pos)
          {:node (if (= op "AND") :and :or) :type :boolean :left l :right r}))))

(defn- bind-cast [cx e]
  (let [arg (bind cx (:arg e))
        {tname :name params :params} (:type-name e)
        target (t/resolve-type tname params "SEMANTIC_ERROR")]
    (when-not (v/castable? (:type arg) target)
      (type-error! (str "cannot CAST " (t/describe (:type arg)) " to " (t/type-name target)) (:pos e)))
    {:node :cast :type target :arg arg}))

(defn- bind-case [cx e]
  (let [operand (some->> (:operand e) (bind cx))
        whens (mapv (fn [[c r]]
                      [(if operand
                         (compare-node "=" operand (bind cx c) (:pos c))
                         (check-boolean! (bind cx c) "CASE WHEN condition" (:pos c)))
                       (bind cx r)])
                    (:whens e))
        else-expr (some->> (:else e) (bind cx))
        results (cond-> (mapv second whens) else-expr (conj else-expr))
        ct (functions/common-type! "CASE" results e)]
    {:node :case :type ct
     :whens (mapv (fn [[c r]] [c (b/coerce r ct)]) whens)
     :else (some-> else-expr (b/coerce ct))}))

(defn- bind-between [cx e]
  (let [x (bind cx (:arg e))
        lo (bind cx (:low e))
        hi (bind cx (:high e))]
    (check-comparable! x lo (:pos e))
    (check-comparable! x hi (:pos e))
    {:node :between :type :boolean :not? (boolean (:not? e)) :arg x :low lo :high hi
     :low-type (t/comparison-type (:type x) (:type lo))
     :high-type (t/comparison-type (:type x) (:type hi))}))

(defn- bind-in-list [cx e]
  (let [x (bind cx (:arg e))
        items (mapv #(bind cx %) (:items e))]
    (doseq [i items] (check-comparable! x i (:pos e)))
    {:node :in-list :type :boolean :not? (boolean (:not? e)) :arg x :items items
     :cmp-types (mapv #(t/comparison-type (:type x) (:type %)) items)}))

(defn- bind-like [cx e]
  (let [x (bind cx (:arg e))
        p (bind cx (:pattern e))]
    (doseq [a [x p]]
      (when-not (#{:string :null} (:type a))
        (type-error! (str "LIKE requires STRING operands, got " (t/describe (:type a))) (:pos e))))
    {:node :like :type :boolean :not? (boolean (:not? e)) :arg x :pattern p}))

(def env-keys
  "Keys of the query analysis environment (see polyquery.sql.analyzer)."
  [:catalog :options :ctes :ids :analyze-query])

(defn- bind-subquery
  "Analyzes a nested query in a new frame whose row is the row `cx`'s
  expressions are evaluated on."
  [cx e kind]
  (let [cell (swap! (:ids cx) inc)
        frame {:scope (:scope cx) :mode (:mode cx) :group-keys (:group-keys cx)
               :cell cell :free (:free cx)}
        own (volatile! #{})
        sub-env (assoc (select-keys cx env-keys) :outer (into [frame] (:outer cx)) :free [own])
        bq ((:analyze-query cx) sub-env (:query e))
        node {:node :subquery :kind kind :cell cell :query bq :correlated? (boolean (seq @own))}
        cols (:columns bq)]
    (when (and (not= kind :exists) (not= 1 (count cols)))
      (semantic! (str "subquery must return exactly one column, got " (count cols)) (:pos e)))
    (case kind
      :exists (assoc node :type :boolean)
      :scalar (assoc node :type (:type (first cols)))
      :in (let [x (bind cx (:arg e))
                ct (:type (first cols))]
            (when-not (t/comparable? (:type x) ct)
              (type-error! (str "cannot compare " (t/describe (:type x)) " with subquery column of type "
                                (t/describe ct)) (:pos e)))
            (assoc node :type :boolean :arg x :not? (boolean (:not? e))
                   :cmp-type (t/comparison-type (:type x) ct))))))

(defn- bind-function [cx e]
  (functions/bind-call (:name e) (mapv #(bind cx %) (:args e)) e
                       {:test-functions? (:test-functions? (:options cx))
                        :eval-constant eval-constant}))

(declare bind*)

(defn bind
  "Binds and type-checks an AST expression."
  [cx e]
  (ctx/poll!)
  (if-let [^IdentityHashMap memo (when (= :plain (:mode cx)) (:plain (:memo cx)))]
    ;; plain binding while matching GROUP BY keys (post-agg-context)
    (let [r (or (.get memo e)
                (let [r (try (bind* cx e) (catch clojure.lang.ExceptionInfo ex ex))]
                  (.put memo e r)
                  r))]
      (if (instance? Throwable r) (throw r) r))
    (bind* cx e)))

(defn- bind*
  [cx e]
  (or
   (when (= :post-agg (:mode cx)) (group-key-ref cx e))
   (case (:node e)
     :literal (bind-literal e)
     :column (bind-column cx e)
     :resolved-column (bind-scope-column cx e e)
     :unary (let [arg (bind cx (:arg e))]
              (when-not (or (= :null (:type arg)) (t/numeric? (:type arg)))
                (type-error! (str "unary " (:op e) " requires a numeric operand, got "
                                  (t/describe (:type arg))) (:pos e)))
              (if (= "-" (:op e))
                {:node :neg :type (:type arg) :arg arg}
                arg))
     :binary (bind-binary cx e)
     :not (let [arg (check-boolean! (bind cx (:arg e)) "operand of NOT" (:pos e))]
            {:node :not :type :boolean :arg arg})
     :is-null {:node :is-null :type :boolean :not? (boolean (:not? e)) :arg (bind cx (:arg e))}
     :cast (bind-cast cx e)
     :func (if (ast/aggregate-call? e) (bind-aggregate cx e) (bind-function cx e))
     :case (bind-case cx e)
     :between (bind-between cx e)
     :in-list (bind-in-list cx e)
     :like (bind-like cx e)
     :subquery (bind-subquery cx e :scalar)
     :exists (bind-subquery cx e :exists)
     :in-query (bind-subquery cx e :in))))

(defn bind-constant-int
  "Binds a LIMIT/OFFSET expression: a constant INT64 expression."
  [cx e what]
  (let [cx (assoc (dissoc cx :memo) :scope [] :mode :plain :outer [] :free []
                  :agg-error (str "aggregates are not allowed in " what))
        not-constant #(semantic! (str what " must be a constant integer expression") (:pos e))
        bound (try (bind cx e)
                   (catch clojure.lang.ExceptionInfo ex
                     (if (= "SEMANTIC_ERROR" (err/error-code ex)) (not-constant) (throw ex))))]
    (when-not (b/constant? bound) (not-constant))
    (when-not (#{:int64 :null} (:type bound))
      (type-error! (str what " must be an INT64 expression, got " (t/describe (:type bound))) (:pos e)))
    bound))
