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
  Aggregate specs: {:fn :count-star|:count|:sum|:avg|:min|:max :distinct? b
                    :arg e :type T}"
  (:require [clojure.string :as str]
            [polyquery.exec.context :as ctx]
            [polyquery.types :as t]
            [polyquery.util.tree :as tree]
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
    :subquery (if (:arg e) [(:arg e)] [])
    []))

(defn map-children
  "Rebuilds e with f applied to each direct sub-expression."
  [f e]
  (case (:node e)
    (:neg :not :is-null :cast) (update e :arg f)
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
  "Post-order rewrite of every node of e with f. Polls the deadline of the
  query being prepared (planning rewrites expressions with it)."
  [f e]
  (ctx/poll!)
  (f (map-children #(transform f %) e)))

(defn nodes
  "All nodes of e (pre-order), not descending into subquery bodies."
  [e]
  (tree/pre-order (constantly true) children e))

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

(defn left-chain
  "Operands, left to right, of the left-deep chain of binary nodes of kind
  (:node) `node` rooted at e: `a || b || c` → [a b c] (a right operand of the
  same kind, i.e. a parenthesized chain, stays one operand)."
  [node e]
  (loop [x e rights ()]
    (if (= node (:node x))
      (recur (:left x) (cons (:right x) rights))
      (vec (cons x rights)))))

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

(defn- write-sql
  "Appends the SQL-like text of e to sb (one buffer for the whole
  expression: linear in its size however deep it is)."
  [^StringBuilder sb e]
  (let [w (fn [& parts]
            (doseq [p parts]
              (if (string? p) (.append sb ^String p) (write-sql sb p))))
        sep (fn [es ^String separator]
              (loop [es (seq es) first? true]
                (when es
                  (when-not first? (.append sb separator))
                  (write-sql sb (first es))
                  (recur (next es) false))))]
    (case (:node e)
      :literal (w (literal-sql e))
      :column (w (str (:name e)))
      :outer-column (w "outer." (str (:name e)))
      :neg (w "-" (:arg e))
      (:arith :compare) (w "(" (:left e) (str " " (:op e) " ") (:right e) ")")
      :concat (w "(" (:left e) " || " (:right e) ")")
      :and (w "(" (:left e) " AND " (:right e) ")")
      :or (w "(" (:left e) " OR " (:right e) ")")
      :not (w "NOT " (:arg e))
      :is-null (w "(" (:arg e) (if (:not? e) " IS NOT NULL)" " IS NULL)"))
      :cast (if (:implicit? e)
              (write-sql sb (:arg e))
              (w "CAST(" (:arg e) (str " AS " (t/type-name (:type e)) ")")))
      :call (do (w (str (:fn e)) "(") (sep (:args e) ", ") (w ")"))
      :case (do (w "CASE")
                (doseq [[c x] (:whens e)] (w " WHEN " c " THEN " x))
                (when (:else e) (w " ELSE " (:else e)))
                (w " END"))
      :like (w "(" (:arg e) (if (:not? e) " NOT LIKE " " LIKE ") (:pattern e) ")")
      :between (w "(" (:arg e) (if (:not? e) " NOT BETWEEN " " BETWEEN ") (:low e) " AND " (:high e) ")")
      :in-list (do (w "(" (:arg e) (if (:not? e) " NOT IN (" " IN ("))
                   (sep (:items e) ", ")
                   (w "))"))
      :subquery (case (:kind e)
                  :scalar (w "(<subquery>)")
                  :exists (w "EXISTS (<subquery>)")
                  :in (w "(" (:arg e) (if (:not? e) " NOT IN (<subquery>))" " IN (<subquery>))")))
      (w (str (:node e))))))

(defn ->sql
  "Renders a bound expression as SQL-like text."
  [e]
  (let [sb (StringBuilder.)]
    (write-sql sb e)
    (.toString sb)))

(defn aggregate->sql [{f :fn distinct? :distinct? arg :arg}]
  (if (= f :count-star)
    "COUNT(*)"
    (str (str/upper-case (name f)) "(" (when distinct? "DISTINCT ") (->sql arg) ")")))
