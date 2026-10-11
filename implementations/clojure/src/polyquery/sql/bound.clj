(ns polyquery.sql.bound
  "Bound (analyzed) expressions: their shapes and generic helpers used by
  the analyzer, the planners and EXPLAIN.

  Bound expressions are maps without source positions, so structural
  equality (GROUP BY matching) is plain `=`. Every node has :node and :type.
    {:node :literal :value v}
    {:node :column :index i :name n}            ; index into the input row
    {:node :outer-column :cell id :index i :name n}
                                                ; column of an enclosing query's
                                                ; row (correlated subqueries)
    {:node :neg :arg e}
    {:node :arith :op op :left e :right e}      ; op ∈ + - * / %
    {:node :concat :left e :right e}
    {:node :compare :op op :cmp-type T :left e :right e}
    {:node :and|:or :left e :right e}
    {:node :not :arg e}
    {:node :is-null :not? b :arg e}
    {:node :cast :arg e}
    {:node :call :fn NAME :args [e …] …}      ; scalar function (extra keys per fn)
    {:node :case :whens [[cond result] …] :else e}
    {:node :like :not? b :arg e :pattern e}
    {:node :between :not? b :arg e :low e :high e :low-type T :high-type T}
    {:node :in-list :not? b :arg e :items [e …] :cmp-types [T …]}
    {:node :subquery :kind :scalar|:exists|:in :cell id :correlated? b
     :query bound-query (after analysis) | :plan physical-plan (after planning)
     [:arg e :cmp-type T :not? b]}               ; for :in
    {:node :in-set :not? b :arg e :cmp-type T :keys java.util.Set :has-null? b
     :exists? b}                                ; x [NOT] IN (subquery) with the
                                                ; subquery's values precomputed
                                                ; (keys per values/key-fn); with
                                                ; :exists?, NULL x gives FALSE
  Aggregate specs: {:fn :count-star|:count|:sum|:avg|:min|:max :distinct? b
                    :arg e :type T}"
  (:require [clojure.string :as str]
            [polyquery.types :as t]
            [polyquery.values :as v]))

(set! *warn-on-reflection* true)

(defn children
  "Direct sub-expressions (not descending into subquery bodies)."
  [e]
  (case (:node e)
    (:neg :not :is-null :cast) [(:arg e)]
    (:arith :concat :compare :and :or) [(:left e) (:right e)]
    :call (:args e)
    :case (concat (mapcat identity (:whens e)) (when (:else e) [(:else e)]))
    :like [(:arg e) (:pattern e)]
    :between [(:arg e) (:low e) (:high e)]
    :in-list (cons (:arg e) (:items e))
    :in-set [(:arg e)]
    :subquery (if (:arg e) [(:arg e)] [])
    []))

(defn map-children
  "Rebuilds e with f applied to each direct sub-expression."
  [f e]
  (case (:node e)
    (:neg :not :is-null :cast :in-set) (update e :arg f)
    (:arith :concat :compare :and :or) (-> e (update :left f) (update :right f))
    :call (update e :args #(mapv f %))
    :case (cond-> (update e :whens (fn [ws] (mapv (fn [[c r]] [(f c) (f r)]) ws)))
            (:else e) (update :else f))
    :like (-> e (update :arg f) (update :pattern f))
    :between (-> e (update :arg f) (update :low f) (update :high f))
    :in-list (-> e (update :arg f) (update :items #(mapv f %)))
    :subquery (if (:arg e) (update e :arg f) e)
    e))

(defn transform
  "Post-order rewrite of every node of e with f."
  [f e]
  (f (map-children #(transform f %) e)))

(defn nodes
  "All nodes of e (pre-order), not descending into subquery bodies."
  [e]
  (tree-seq (constantly true) children e))

(defn column-indices
  "Set of input-row indices referenced by e."
  [e]
  (into #{} (keep #(when (= :column (:node %)) (:index %))) (nodes e)))

(defn correlated?
  "True if e contains a correlated subquery."
  [e]
  (boolean (some #(and (= :subquery (:node %)) (:correlated? %)) (nodes e))))

(defn constant?
  "True if e does not depend on any row (no columns, subqueries)."
  [e]
  (not-any? #(#{:column :outer-column :subquery} (:node %)) (nodes e)))

(defn shift-columns
  "Adds delta to every input column index of e."
  [e ^long delta]
  (if (zero? delta)
    e
    (transform #(if (= :column (:node %)) (update % :index + delta) %) e)))

(defn conjuncts
  "Splits a predicate into its top-level AND conjuncts."
  [e]
  (cond
    (nil? e) []
    (= :and (:node e)) (into (conjuncts (:left e)) (conjuncts (:right e)))
    :else [e]))

(defn conjoin
  "AND of the predicates (nil for none)."
  [es]
  (when (seq es)
    (reduce (fn [l r] {:node :and :type :boolean :left l :right r}) es)))

(defn column-ref
  [index type name]
  {:node :column :type type :index index :name name})

(defn coerce
  "Wraps e in an implicit conversion to type `to` (numeric promotion) unless
  it already has that type."
  [e to]
  (if (or (= (:type e) to) (= :null to))
    e
    {:node :cast :type to :arg e :implicit? true}))

;; ---------------------------------------------------------------------------
;; Rendering (EXPLAIN)

(defn- literal-sql [{:keys [type value]}]
  (if (nil? value)
    "NULL"
    (case (t/kind type)
      :string (str "'" (str/replace value "'" "''") "'")
      :date (str "DATE '" (v/format-date value) "'")
      :timestamp (str "TIMESTAMP '" (v/format-timestamp value) "'")
      (v/value->string type value))))

(defn ->sql
  "Renders a bound expression as SQL-like text."
  [e]
  (let [r ->sql]
    (case (:node e)
      :literal (literal-sql e)
      :column (str (:name e))
      :outer-column (str "outer." (:name e))
      :neg (str "-" (r (:arg e)))
      (:arith :compare) (str "(" (r (:left e)) " " (:op e) " " (r (:right e)) ")")
      :concat (str "(" (r (:left e)) " || " (r (:right e)) ")")
      :and (str "(" (r (:left e)) " AND " (r (:right e)) ")")
      :or (str "(" (r (:left e)) " OR " (r (:right e)) ")")
      :not (str "NOT " (r (:arg e)))
      :is-null (str "(" (r (:arg e)) (if (:not? e) " IS NOT NULL)" " IS NULL)"))
      :cast (if (:implicit? e)
              (r (:arg e))
              (str "CAST(" (r (:arg e)) " AS " (t/type-name (:type e)) ")"))
      :call (str (:fn e) "(" (str/join ", " (map r (:args e))) ")")
      :case (str "CASE"
                 (apply str (for [[c x] (:whens e)] (str " WHEN " (r c) " THEN " (r x))))
                 (when (:else e) (str " ELSE " (r (:else e))))
                 " END")
      :like (str "(" (r (:arg e)) (when (:not? e) " NOT") " LIKE " (r (:pattern e)) ")")
      :between (str "(" (r (:arg e)) (when (:not? e) " NOT") " BETWEEN " (r (:low e))
                    " AND " (r (:high e)) ")")
      :in-list (str "(" (r (:arg e)) (when (:not? e) " NOT") " IN ("
                    (str/join ", " (map r (:items e))) "))")
      :in-set (str "(" (r (:arg e)) (when (:not? e) " NOT") " IN (<" (count (:keys e))
                   (if (:has-null? e) " values and NULL>))" " values>))"))
      :subquery (case (:kind e)
                  :scalar "(<subquery>)"
                  :exists "EXISTS (<subquery>)"
                  :in (str "(" (r (:arg e)) (when (:not? e) " NOT") " IN (<subquery>))"))
      (str (:node e)))))

(defn aggregate->sql [{f :fn distinct? :distinct? arg :arg}]
  (if (= f :count-star)
    "COUNT(*)"
    (str (str/upper-case (name f)) "(" (when distinct? "DISTINCT ") (->sql arg) ")")))
