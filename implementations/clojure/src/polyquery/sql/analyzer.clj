(ns polyquery.sql.analyzer
  "Semantic analysis: name resolution, typing and validation of a parsed
  statement against a catalog snapshot (spec/sql/semantics.md,
  spec/data-types/types.md). Produces a *bound query*: a description of the
  query whose expressions are bound expressions (see below), ready for the
  planner.

  Bound expressions are maps without source positions (so that structural
  equality is plain `=`):
    {:node :literal :type T :value v}
    {:node :column :type T :index i :name n}     ; index into the input row
    {:node :neg :type T :arg e}
    {:node :arith :op op :type T :left e :right e}  ; op ∈ + - * / %
    {:node :concat :type :string :left e :right e}
    {:node :compare :op op :type :boolean :cmp-type T :left e :right e}
    {:node :and|:or :type :boolean :left e :right e}
    {:node :not :type :boolean :arg e}
    {:node :is-null :type :boolean :not? b :arg e}
    {:node :cast :type T :arg e}
    {:node :call :fn name :type T :args [e …]}
  Aggregate specs: {:fn :count-star|:count|:sum|:avg|:min|:max :distinct? b
                    :arg e :type T}"
  (:require [clojure.string :as str]
            [polyquery.catalog :as catalog]
            [polyquery.errors :as err]
            [polyquery.sql.ast :as ast]
            [polyquery.sql.functions :as functions]
            [polyquery.types :as t]
            [polyquery.util.text :as text]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Errors

(defn- details [pos] (when pos {"line" (:line pos) "column" (:col pos)}))

(defn semantic! [msg pos] (err/fail! "SEMANTIC_ERROR" msg (details pos)))
(defn type-error! [msg pos] (err/fail! "TYPE_ERROR" msg (details pos)))
(defn unsupported! [what pos] (err/fail! "UNSUPPORTED" (str what " is not supported") (details pos)))

;; ---------------------------------------------------------------------------
;; Scopes. A scope is a vector of range variables
;; {:name alias :columns [{:name :type :index}]}; :index is the position of the
;; column in the input row.

(defn table-scope
  [table alias]
  [{:name (or alias (:name table))
    :columns (vec (map-indexed (fn [i c] {:name (:name c) :type (:type c) :index i})
                               (:columns table)))}])

(defn- find-range-var [scope qualifier]
  (let [k (text/ascii-lower qualifier)]
    (first (filter #(= k (text/ascii-lower (:name %))) scope))))

(defn- matching-columns [rv cname]
  (let [k (text/ascii-lower cname)]
    (filter #(= k (text/ascii-lower (:name %))) (:columns rv))))

(defn- resolve-column
  [scope {:keys [table name pos]}]
  (if table
    (let [rv (or (find-range-var scope table)
                 (semantic! (str "unknown table or alias '" table "'") pos))
          cols (matching-columns rv name)]
      (case (count cols)
        0 (semantic! (str "unknown column '" table "." name "'") pos)
        1 (first cols)
        (semantic! (str "ambiguous column '" table "." name "'") pos)))
    (let [cols (mapcat #(matching-columns % name) scope)]
      (case (count cols)
        0 (semantic! (str "unknown column '" name "'") pos)
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
                u (if (empty? digits) 0 (Long/parseLong digits))]
            {:node :literal :type (t/decimal p s) :value (if neg? (- u) u)})))

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
                  ("+" "-") (t/decimal 18 (max (t/scale lt') (t/scale rt')))
                  "*" (let [s (+ (t/scale lt') (t/scale rt'))]
                        (when (> s t/max-decimal-precision)
                          (type-error! (str "DECIMAL multiplication result scale " s " exceeds 18") pos))
                        (t/decimal 18 s))
                  "/" :float64
                  "%" (bad)))))))

(defn comparison-type
  "Type in which two comparable operands are compared."
  [lt rt]
  (cond
    (= lt :null) rt
    (= rt :null) lt
    (and (t/numeric? lt) (t/numeric? rt)) (if (= lt rt) lt (t/common-numeric-type lt rt))
    (and (t/temporal? lt) (t/temporal? rt)) (if (= lt rt) lt :timestamp)
    :else lt))

(defn- check-boolean! [e what pos]
  (when-not (#{:boolean :null} (:type e))
    (type-error! (str what " must be BOOLEAN, got " (t/describe (:type e))) pos))
  e)

;; ---------------------------------------------------------------------------
;; Expression binding
;;
;; The binding context `cx` holds:
;;   :scope       input scope (vector of range variables, possibly empty)
;;   :mode        :plain    — plain row expression; aggregates rejected
;;                :post-agg — expression over the aggregation output
;;                :in-agg   — inside an aggregate argument
;;   :agg-error   message used when an aggregate appears in :plain mode
;;   :aggs        volatile vector of aggregate specs (post-agg mode)
;;   :group-keys  bound GROUP BY expressions (post-agg mode)
;;   :options     analysis options (e.g. :test-functions?)

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
                                    :decimal (t/decimal 18 (t/scale at))
                                    :null :null
                                    at)})
                 "AVG" (do (when-not (or (= at :null) (t/numeric? at))
                             (type-error! (str "AVG requires a numeric argument, got " (t/describe at)) pos))
                           {:fn :avg :arg arg :type :float64})
                 "MIN" {:fn :min :arg arg :type at}
                 "MAX" {:fn :max :arg arg :type at})
          spec (assoc spec :distinct? (boolean (:distinct? e)))
          aggs (:aggs cx)
          idx (or (first (keep-indexed (fn [i a] (when (= a spec) i)) @aggs))
                  (do (vswap! aggs conj spec) (dec (count @aggs))))]
      {:node :column :type (:type spec) :index (+ (count (:group-keys cx)) idx)
       :name (str "agg" idx)})))

(defn- group-key-ref
  "In post-agg mode: a reference to the GROUP BY key structurally equal to
  aggregate-free expression e, or nil."
  [cx e]
  (when (and (seq (:group-keys cx)) (not= :literal (:node e)) (not (ast/contains-aggregate? e)))
    (let [bound (try (bind (assoc cx :mode :plain) e)
                     (catch clojure.lang.ExceptionInfo _ nil))]
      (when bound
        (first (keep-indexed (fn [i g] (when (= g bound)
                                         {:node :column :type (:type g) :index i :name (str "key" i)}))
                             (:group-keys cx)))))))

(defn- bind-column [cx e]
  (let [col (resolve-column (:scope cx) e)]
    (when (= :post-agg (:mode cx))
      (semantic! (str "column '" (:name e) "' must appear in GROUP BY or be used in an aggregate function")
                 (:pos e)))
    {:node :column :type (:type col) :index (:index col) :name (:name col)}))

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
      (do (when-not (t/comparable? lt rt)
            (type-error! (str "cannot compare " (t/describe lt) " with " (t/describe rt)) pos))
          {:node :compare :op op :type :boolean :cmp-type (comparison-type lt rt) :left l :right r})

      ("AND" "OR")
      (do (check-boolean! l (str "operand of " op) pos)
          (check-boolean! r (str "operand of " op) pos)
          {:node (if (= op "AND") :and :or) :type :boolean :left l :right r}))))

(defn- bind-cast [cx e]
  (let [arg (bind cx (:arg e))
        {tname :name params :params tpos :pos} (:type-name e)
        target (t/resolve-type tname params "SEMANTIC_ERROR")]
    (when-not (v/castable? (:type arg) target)
      (type-error! (str "cannot CAST " (t/describe (:type arg)) " to " (t/type-name target)) (:pos e)))
    {:node :cast :type target :arg arg}))

(defn bind
  "Binds and type-checks an AST expression."
  [cx e]
  (or
   (when (= :post-agg (:mode cx)) (group-key-ref cx e))
   (case (:node e)
     :literal (bind-literal e)
     :column (bind-column cx e)
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
     :is-null {:node :is-null :type :boolean :not? (:not? e) :arg (bind cx (:arg e))}
     :cast (bind-cast cx e)
     :func (if (ast/aggregate-call? e)
             (bind-aggregate cx e)
             (functions/bind-call (:name e) (mapv #(bind cx %) (:args e)) e (:options cx)))
     (:between :in-list :like :case) (unsupported! (name (:node e)) (:pos e))
     (:in-query :exists :subquery) (unsupported! "subqueries" (:pos e)))))

;; ---------------------------------------------------------------------------
;; Constant expressions (LIMIT / OFFSET)

(defn- bind-constant-int
  [e what options]
  (let [cx {:scope [] :mode :plain :options options
            :agg-error (str "aggregates are not allowed in " what)}
        b (try (bind cx e)
               (catch clojure.lang.ExceptionInfo ex
                 (if (= "SEMANTIC_ERROR" (err/error-code ex))
                   (semantic! (str what " must be a constant integer expression") (:pos e))
                   (throw ex))))]
    (when-not (#{:int64 :null} (:type b))
      (type-error! (str what " must be an INT64 expression, got " (t/describe (:type b))) (:pos e)))
    b))

;; ---------------------------------------------------------------------------
;; Queries

(defn- resolve-from
  [catalog from]
  (case (:node from)
    nil [nil []]
    :table (let [tbl (or (catalog/lookup catalog (:name from))
                         (semantic! (str "unknown table '" (:name from) "'") (:pos from)))]
             [{:table tbl :alias (:alias from)} (table-scope tbl (:alias from))])
    :derived (unsupported! "derived tables" (:pos from))
    :join (unsupported! "joins" (:pos from))))

(defn- expand-items
  "Expands * and r.* into column-reference items."
  [scope items]
  (vec
   (mapcat
    (fn [item]
      (if (= :star (:kind item))
        (let [rvs (if (:table item)
                    [(or (find-range-var scope (:table item))
                         (semantic! (str "unknown table or alias '" (:table item) "'") (:pos item)))]
                    scope)]
          (when (empty? rvs) (semantic! "SELECT * requires a FROM clause" (:pos item)))
          (for [rv rvs col (:columns rv)]
            {:kind :expr :pos (:pos item)
             :expr {:node :column :table (:name rv) :name (:name col) :pos (:pos item)}}))
        [item]))
    items)))

(defn- output-name [item bound n]
  (or (:alias item)
      (when (= :column (:node (:expr item))) (:name bound))
      (str "_col" n)))

(defn- ordinal [e]
  (when (and (= :literal (:node e)) (= :number (:kind e)) (re-matches #"[0-9]+" (:text e)))
    (try (Long/parseLong (:text e)) (catch NumberFormatException _ Long/MAX_VALUE))))

(defn- resolve-order-item
  "Returns {:output i} for references to output columns, else {:expr bound}."
  [cx outputs item]
  (let [e (:expr item)
        pos (:pos e)]
    (if-let [k (ordinal e)]
      (if (<= 1 k (count outputs))
        {:output (dec k)}
        (semantic! (str "ORDER BY position " k " is out of range") pos))
      (let [by-name (when (and (= :column (:node e)) (nil? (:table e)))
                      (let [k (text/ascii-lower (:name e))]
                        (filter #(= k (text/ascii-lower (:name (nth outputs %)))) (range (count outputs)))))]
        (cond
          (= 1 (count by-name)) {:output (first by-name)}
          (> (count by-name) 1)
          (if (apply = (map #(:expr (nth outputs %)) by-name))
            {:output (first by-name)}
            (semantic! (str "ORDER BY column '" (:name e) "' is ambiguous") pos))
          :else
          (let [b (bind cx e)
                same (first (filter #(= b (:expr (nth outputs %))) (range (count outputs))))]
            (if same {:output same} {:expr b})))))))

(defn analyze-query
  "Analyzes a :query AST node. Returns the bound query:
  {:source {:table :alias}|nil :where e :aggregated? b :group-keys [e]
   :aggregates [spec] :having e :outputs [{:name :type :expr}]
   :order-by [{:output i | :expr e, :desc? b, :nulls-first? b}]
   :limit e|nil :offset e|nil}"
  [catalog q options]
  (let [core (:select q)]
    (when (seq (:with q)) (unsupported! "WITH" (:pos q)))
    (when (:distinct? core) (unsupported! "SELECT DISTINCT" (:pos core)))
    (when (seq (:group-by core)) (unsupported! "GROUP BY" (:pos (first (:group-by core)))))
    (let [[source scope] (resolve-from catalog (:from core))
          items (expand-items scope (:items core))
          aggregated? (boolean (or (seq (:group-by core))
                                   (:having core)
                                   (some #(ast/contains-aggregate? (:expr %)) items)
                                   (some #(ast/contains-aggregate? (:expr %)) (:order-by q))))
          base {:scope scope :options options :mode :plain}
          where (when-let [w (:where core)]
                  (check-boolean! (bind (assoc base :agg-error "aggregates are not allowed in WHERE") w)
                                  "WHERE condition" (:pos w)))
          aggs (volatile! [])
          group-keys []
          cx (if aggregated?
               (assoc base :mode :post-agg :aggs aggs :group-keys group-keys)
               (assoc base :agg-error "aggregates are not allowed here"))
          outputs (vec (map-indexed
                        (fn [i item]
                          (let [b (bind cx (:expr item))]
                            {:name (output-name item b (inc i)) :type (:type b) :expr b}))
                        items))
          having (when-let [h (:having core)]
                   (check-boolean! (bind cx h) "HAVING condition" (:pos h)))
          order-by (mapv (fn [item]
                           (assoc (resolve-order-item cx outputs item)
                                  :desc? (:desc? item)
                                  :nulls-first? (case (:nulls item)
                                                  :first true
                                                  :last false
                                                  (not (:desc? item)))))
                         (:order-by q))
          limit (some-> (:limit q) (bind-constant-int "LIMIT" options))
          offset (some-> (:offset q) (bind-constant-int "OFFSET" options))]
      {:source source
       :where where
       :aggregated? aggregated?
       :group-keys group-keys
       :aggregates @aggs
       :having having
       :outputs outputs
       :order-by order-by
       :limit limit
       :offset offset})))

(defn analyze-statement
  "Analyzes a parsed statement against a catalog snapshot."
  [catalog stmt options]
  (case (:node stmt)
    :select {:kind :query :query (analyze-query catalog (:query stmt) options)}
    :explain (unsupported! "EXPLAIN" (:pos stmt))
    (:create-index :drop-index) (unsupported! "index statements" (:pos stmt))))
