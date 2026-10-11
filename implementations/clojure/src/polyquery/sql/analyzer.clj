(ns polyquery.sql.analyzer
  "Semantic analysis of statements against a catalog snapshot: FROM
  resolution (tables, CTEs, derived tables, joins), `*` expansion, clause
  validation (WHERE, GROUP BY, HAVING, ORDER BY, LIMIT), aggregation rules
  and output naming (spec/sql/semantics.md). Expressions are bound by
  polyquery.sql.binder.

  The analysis environment `env` holds:
    :catalog        catalog snapshot
    :options        analysis options (e.g. :test-functions?)
    :ctes           visible CTEs, innermost first: [{:name :query :columns}]
    :outer          frames of enclosing queries (innermost first) for
                    correlated column references:
                    {:scope :mode :group-keys :cell :free}
    :free           volatiles collecting the cells of enclosing frames the
                    current query references (non-empty ⇒ correlated)
    :ids            atom generating cell ids
    :analyze-query  this namespace's analyze-query (used by the binder)

  The result of analyzing a query is a *bound query*:
    {:from rel|nil :where e :aggregated? b :group-keys [e] :aggregates [spec]
     :having e :outputs [{:name :type :expr}] :distinct? b
     :order-by [{:output i | :expr e, :desc? b, :nulls-first? b}]
     :limit e :offset e :columns [{:name :type}]}
  or, for `core UNION ALL core …`, a bound compound query
    {:union [bound-query …] :order-by [{:output i …}] :limit e :offset e
     :columns [{:name :type}]}
  Relations (rel):
    {:rel :scan :table T :name alias :columns [{:name :type}]}
    {:rel :query :query bound-query :name alias :columns [{:name :type}]}
    {:rel :join :kind :inner|:left|:cross :left rel :right rel :on e}
  The expressions of a query are evaluated on its FROM row: the
  concatenation of the columns of all range variables in FROM order (after
  aggregation: GROUP BY keys followed by aggregate values)."
  (:require [polyquery.catalog :as catalog]
            [polyquery.sql.ast :as ast]
            [polyquery.sql.binder :as binder :refer [semantic!]]
            [polyquery.sql.bound :as b]
            [polyquery.types :as t]))

(set! *warn-on-reflection* true)

(declare analyze-query)

;; ---------------------------------------------------------------------------
;; FROM

(defn- range-var
  [name columns offset]
  {:name name
   :columns (vec (map-indexed (fn [^long i c] {:name (:name c) :type (:type c) :index (+ (long offset) i)}) columns))})

(defn- shift-scope [scope ^long delta]
  (mapv (fn [rv] (update rv :columns (fn [cs] (mapv #(update % :index + delta) cs)))) scope))

(defn- lookup-cte [env tname]
  (first (filter #(binder/same-name? tname (:name %)) (:ctes env))))

(defn- resolve-from
  "Resolves a FROM item. Returns [rel scope]; scope indices start at 0."
  [env from]
  (case (:node from)
    :table
    (if-let [cte (lookup-cte env (:name from))]
      (let [rname (or (:alias from) (:name from))]
        [{:rel :query :query (:query cte) :name rname :columns (:columns cte)}
         [(range-var rname (:columns cte) 0)]])
      (let [tbl (or (catalog/lookup (:catalog env) (:name from))
                    (semantic! (str "unknown table '" (:name from) "'") (:pos from)))
            rname (or (:alias from) (:name tbl))]
        [{:rel :scan :table tbl :name rname :columns (:columns tbl)}
         [(range-var rname (:columns tbl) 0)]]))

    :derived
    (let [bq (analyze-query env (:query from))]
      [{:rel :query :query bq :name (:alias from) :columns (:columns bq)}
       [(range-var (:alias from) (:columns bq) 0)]])

    :join
    (let [[lrel lscope] (resolve-from env (:left from))
          [rrel rscope] (resolve-from env (:right from))
          width (reduce + (map (comp count :columns) lscope))
          scope (into lscope (shift-scope rscope width))]
      (doseq [rv rscope]
        (when (binder/find-range-var lscope (:name rv))
          (semantic! (str "duplicate table name or alias '" (:name rv) "' in FROM") (:pos from))))
      [{:rel :join :kind (:kind from) :left lrel :right rrel
        :on (when-let [on (:on from)]
              (binder/check-boolean!
               (binder/bind (assoc env :scope scope :mode :plain
                                   :agg-error "aggregates are not allowed in ON")
                            on)
               "ON condition" (:pos on)))}
       scope])))

;; ---------------------------------------------------------------------------
;; SELECT list

(defn- expand-items
  "Expands * and r.* into resolved column items."
  [scope items]
  (vec
   (mapcat
    (fn [item]
      (if (= :star (:kind item))
        (let [rvs (if (:table item)
                    [(or (binder/find-range-var scope (:table item))
                         (semantic! (str "unknown table or alias '" (:table item) "'") (:pos item)))]
                    scope)]
          (when (empty? rvs) (semantic! "SELECT * requires a FROM clause" (:pos item)))
          (for [rv rvs col (:columns rv)]
            {:kind :expr :pos (:pos item)
             :expr (assoc col :node :resolved-column :pos (:pos item))}))
        [item]))
    items)))

(defn- output-name [item bound n]
  (or (:alias item)
      (when (and (#{:column :resolved-column} (:node (:expr item)))
                 (#{:column :outer-column} (:node bound)))
        (:name bound))
      (str "_col" n)))

(defn- ordinal
  "The value of a positive-integer literal, else nil."
  [e]
  (when (and (= :literal (:node e)) (= :number (:kind e)) (re-matches #"[0-9]+" (:text e)))
    (try (Long/parseLong (:text e)) (catch NumberFormatException _ Long/MAX_VALUE))))

(defn- bare-name [e]
  (when (and (= :column (:node e)) (nil? (:table e))) (:name e)))

;; ---------------------------------------------------------------------------
;; GROUP BY / ORDER BY

(defn- group-by-expr
  "The expression a GROUP BY item stands for: select-list ordinals and
  aliases are replaced by the select item's expression."
  [scope items g]
  (if-let [k (ordinal g)]
    (if (<= 1 k (count items))
      (:expr (nth items (dec (long k))))
      (semantic! (str "GROUP BY position " k " is out of range") (:pos g)))
    (or (when-let [nm (bare-name g)]
          (when-not (binder/lookup-column scope g)
            (some #(when (and (:alias %) (binder/same-name? nm (:alias %))) (:expr %)) items)))
        g)))

(defn- resolve-order-item
  "Returns {:output i} for references to output columns, else {:expr bound}."
  [cx outputs distinct? item]
  (let [e (:expr item)
        pos (:pos e)]
    (if-let [k (ordinal e)]
      (if (<= 1 k (count outputs))
        {:output (dec (long k))}
        (semantic! (str "ORDER BY position " k " is out of range") pos))
      (let [by-name (when-let [nm (bare-name e)]
                      (filter #(binder/same-name? nm (:name (nth outputs %))) (range (count outputs))))]
        (cond
          (= 1 (count by-name)) {:output (first by-name)}
          (> (count by-name) 1)
          (if (apply = (map #(:expr (nth outputs %)) by-name))
            {:output (first by-name)}
            (semantic! (str "ORDER BY column '" (:name e) "' is ambiguous") pos))
          :else
          (let [bound (binder/bind cx e)
                same (first (filter #(= bound (:expr (nth outputs %))) (range (count outputs))))]
            (cond
              same {:output same}
              distinct? (semantic! "ORDER BY expressions of a SELECT DISTINCT must appear in the select list"
                                   pos)
              :else {:expr bound})))))))

(defn- order-direction
  "Direction and NULL placement of an ORDER BY item (types.md: NULLs sort
  before every value, unless NULLS FIRST/LAST says otherwise)."
  [item]
  {:desc? (:desc? item)
   :nulls-first? (case (:nulls item)
                   :first true
                   :last false
                   (not (:desc? item)))})

(defn- bind-limits
  "LIMIT and OFFSET of a query."
  [env q]
  {:limit (some-> (:limit q) (#(binder/bind-constant-int env % "LIMIT")))
   :offset (some-> (:offset q) (#(binder/bind-constant-int env % "OFFSET")))})

;; ---------------------------------------------------------------------------
;; Queries

(defn- analyze-ctes
  "Analyzes a WITH clause; returns env with the CTEs visible."
  [env ctes]
  (reduce
   (fn [env {cname :name cols :columns q :query pos :pos}]
     (let [bq (analyze-query env q)
           out (:columns bq)]
       (when (and cols (not= (count cols) (count out)))
         (semantic! (str "CTE '" cname "' has " (count cols) " column names but its query returns "
                         (count out) " columns") pos))
       (update env :ctes #(cons {:name cname :query bq
                                 :columns (if cols
                                            (mapv (fn [c n] (assoc c :name n)) out cols)
                                            out)}
                                %))))
   (do
     (reduce (fn [seen {cname :name pos :pos}]
               (when (some #(binder/same-name? cname %) seen)
                 (semantic! (str "duplicate CTE name '" cname "'") pos))
               (conj seen cname))
             [] ctes)
     env)
   ctes))

(defn- analyze-select
  [env q]
  (let [core (:select q)
        [rel scope] (if (:from core) (resolve-from env (:from core)) [nil []])
        items (expand-items scope (:items core))
        aggregated? (boolean (or (seq (:group-by core))
                                 (:having core)
                                 (some #(ast/contains-aggregate? (:expr %)) items)
                                 (some #(ast/contains-aggregate? (:expr %)) (:order-by q))))
        base (assoc env :scope scope :mode :plain)
        where (when-let [w (:where core)]
                (binder/check-boolean!
                 (binder/bind (assoc base :agg-error "aggregates are not allowed in WHERE") w)
                 "WHERE condition" (:pos w)))
        group-keys (mapv #(binder/bind (assoc base :agg-error "aggregates are not allowed in GROUP BY")
                                       (group-by-expr scope items %))
                         (:group-by core))
        aggs (volatile! [])
        cx (if aggregated?
             (assoc base :mode :post-agg :aggs aggs :group-keys group-keys)
             (assoc base :agg-error "aggregates are not allowed here"))
        outputs (vec (map-indexed
                      (fn [^long i item]
                        (let [bound (binder/bind cx (:expr item))]
                          {:name (output-name item bound (inc i)) :type (:type bound) :expr bound}))
                      items))
        having (when-let [h (:having core)]
                 (binder/check-boolean! (binder/bind cx h) "HAVING condition" (:pos h)))
        order-by (mapv #(merge (resolve-order-item cx outputs (:distinct? core) %) (order-direction %))
                       (:order-by q))
        limits (bind-limits env q)]
    {:from rel
     :where where
     :aggregated? aggregated?
     :group-keys group-keys
     :aggregates @aggs
     :having having
     :outputs outputs
     :distinct? (boolean (:distinct? core))
     :order-by order-by
     :limit (:limit limits)
     :offset (:offset limits)
     :columns (mapv #(select-keys % [:name :type]) outputs)}))

;; ---------------------------------------------------------------------------
;; UNION ALL (spec/changes/union-all.md)

(defn- union-column-type
  "Common type of output column i of all branches (CASE result rule: numeric
  promotion, untyped NULL adopts the other types), or TYPE_ERROR."
  [branches i pos]
  (reduce (fn [acc bq]
            (let [ct (:type (nth (:columns bq) i))]
              (or (t/common-type acc ct)
                  (binder/type-error! (str "UNION ALL column " (inc (long i)) " has incompatible types "
                                           (t/describe acc) " and " (t/describe ct))
                                      pos))))
          :null branches))

(defn- coerce-outputs
  "Branch bq with its outputs converted to the compound's column types."
  [bq types]
  (let [outputs (mapv (fn [o ty] (assoc o :type ty :expr (b/coerce (:expr o) ty))) (:outputs bq) types)]
    (assoc bq :outputs outputs :columns (mapv #(select-keys % [:name :type]) outputs))))

(defn- compound-order-item
  "ORDER BY item of a compound query: an output column name (of the first
  branch) or a 1-based position; anything else is a SEMANTIC_ERROR."
  [columns item]
  (let [e (:expr item)
        pos (:pos e)
        idx (if-let [k (ordinal e)]
              (if (<= 1 k (count columns))
                (dec (long k))
                (semantic! (str "ORDER BY position " k " is out of range") pos))
              (let [nm (or (bare-name e)
                           (semantic! (str "ORDER BY items of a UNION ALL query must be output column "
                                           "names or positions") pos))
                    hits (filter #(binder/same-name? nm (:name (nth columns %))) (range (count columns)))]
                (case (count hits)
                  0 (semantic! (str "ORDER BY column '" nm "' is not an output column of the UNION ALL")
                               pos)
                  1 (first hits)
                  (semantic! (str "ORDER BY column '" nm "' is ambiguous") pos))))]
    (assoc (order-direction item) :output idx)))

(defn- analyze-union-all
  "Analyzes `core UNION ALL core …` with ORDER BY/LIMIT over the whole
  result. The bound compound query is
    {:union [bound-query …] :order-by [{:output i :desc? :nulls-first?}]
     :limit e :offset e :columns [{:name :type}]}
  whose branches' outputs are already converted to the column types."
  [env q]
  (let [cores (into [(:select q)] (:union-all q))
        branches (mapv #(analyze-select env {:select %}) cores)
        width (count (:columns (first branches)))
        _ (doseq [[bq core] (map vector branches cores)]
            (when (not= width (count (:columns bq)))
              (semantic! (str "UNION ALL branches must have the same number of columns: " width
                              " and " (count (:columns bq)))
                         (:pos core))))
        types (mapv #(union-column-type branches % (:pos q)) (range width))
        branches (mapv #(coerce-outputs % types) branches)
        columns (mapv (fn [c ty] {:name (:name c) :type ty}) (:columns (first branches)) types)]
    (merge {:union branches
            :order-by (mapv #(compound-order-item columns %) (:order-by q))
            :columns columns}
           (bind-limits env q))))

(defn analyze-query
  "Analyzes a :query AST node in env; returns the bound query (or bound
  compound query, see analyze-union-all)."
  [env q]
  (let [env (analyze-ctes env (:with q))]
    (if (seq (:union-all q))
      (analyze-union-all env q)
      (analyze-select env q))))

(defn root-env
  [catalog options]
  {:catalog catalog :options options :ctes () :outer [] :free [] :ids (atom 0)
   :analyze-query analyze-query})

(defn- analyze-create-index
  "Validates CREATE INDEX: the table and column must exist."
  [catalog {:keys [name table column kind if-not-exists? pos]}]
  (let [tbl (or (catalog/lookup catalog table)
                (semantic! (str "unknown table '" table "'") pos))
        ci (or (first (keep-indexed (fn [i c] (when (binder/same-name? column (:name c)) i))
                                    (:columns tbl)))
               (semantic! (str "unknown column '" column "' in table '" (:name tbl) "'") pos))]
    {:kind :create-index :index-name name :table (:name tbl) :column-index ci
     :index-kind kind :if-not-exists? if-not-exists?}))

(defn analyze-statement
  "Analyzes a parsed statement against a catalog snapshot. Returns
  {:kind :query|:explain :query bound-query}, or for index statements
  {:kind :create-index :index-name :table :column-index :index-kind
  :if-not-exists?} / {:kind :drop-index :index-name :if-exists?}."
  [catalog stmt options]
  (let [env (root-env catalog options)]
    (case (:node stmt)
      :select {:kind :query :query (analyze-query env (:query stmt))}
      :explain {:kind :explain :query (analyze-query env (:query stmt))}
      :create-index (analyze-create-index catalog stmt)
      :drop-index {:kind :drop-index :index-name (:name stmt) :if-exists? (:if-exists? stmt)})))
