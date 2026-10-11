(ns polyquery.plan.logical
  "The logical plan: a tree of relational operators independent of any
  execution strategy, built from a bound query (polyquery.sql.analyzer).
  Expressions stay bound expressions (polyquery.sql.bound). The logical
  optimizer (polyquery.plan.optimizer) rewrites it; the physical planner
  (polyquery.plan.physical) alone chooses how it is executed.

  Logical nodes ({:op …}); every node carries :width (columns per row):
    {:op :values  :rows [[…]]}                      ; constant rows (no FROM)
    {:op :scan    :table T :alias a :columns [i …]}  ; table columns read
    {:op :derived :alias a :input P}                ; derived table / CTE
    {:op :join    :kind :inner|:left|:cross :left P :right P :condition e}
    {:op :filter  :input P :predicate e}
    {:op :aggregate :input P :group-keys [e] :aggregates [spec]}
    {:op :project :input P :exprs [e] :names [n]}
    {:op :distinct :input P}
    {:op :sort    :input P :keys [{:index i :type T :desc? b :nulls-first? b}]}
    {:op :limit   :input P :limit e|nil :offset e|nil}
    {:op :union-all :inputs [P …]}                 ; concatenation (UNION ALL)
  The root of a query plan also carries :columns [{:name :type}]; the plan
  of an EXISTS subquery carries :required-outputs #{} (only the existence
  of rows matters). CTEs are inlined as :derived nodes at each reference.

  Subqueries in expressions keep their bound query and carry its logical
  plan:  {:node :subquery … :query bound-query :logical P}"
  (:require [clojure.string :as str]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Generic traversal

(defn inputs
  "The input plans of node."
  [node]
  (case (:op node)
    :join [(:left node) (:right node)]
    :union-all (:inputs node)
    (if (:input node) [(:input node)] [])))

(defn map-inputs
  "node with f applied to each of its inputs."
  [f node]
  (case (:op node)
    :join (-> node (update :left f) (update :right f))
    :union-all (update node :inputs #(mapv f %))
    (if (:input node) (update node :input f) node)))

(defn exprs
  "The expressions node evaluates (sort keys are output indices)."
  [node]
  (remove nil?
          (case (:op node)
            :filter [(:predicate node)]
            :join [(:condition node)]
            :aggregate (concat (:group-keys node) (keep :arg (:aggregates node)))
            :project (:exprs node)
            :limit [(:limit node) (:offset node)]
            [])))

(defn map-exprs
  "node with f applied to each of its expressions (see exprs)."
  [f node]
  (let [f' #(when % (f %))]
    (case (:op node)
      :filter (update node :predicate f')
      :join (update node :condition f')
      :aggregate (-> node
                     (update :group-keys #(mapv f %))
                     (update :aggregates (fn [as] (mapv #(if (:arg %) (update % :arg f) %) as))))
      :project (update node :exprs #(mapv f %))
      :limit (-> node (update :limit f') (update :offset f'))
      node)))

(defn walk
  "Post-order rewrite of every node of the plan (derived tables and UNION
  ALL branches included, subquery plans not) with f."
  [f node]
  (f (map-inputs #(walk f %) node)))

(defn map-subquery-plans
  "plan with f applied to the logical plan of every subquery expression in
  it (not to the plans nested in those)."
  [f plan]
  (walk (fn [node]
          (map-exprs (fn [e]
                       (b/transform #(if (and (= :subquery (:node %)) (:logical %)) (update % :logical f) %)
                                    e))
                     node))
        plan))

;; ---------------------------------------------------------------------------
;; Construction

(declare plan-query build)

(defn plan-relation
  [rel]
  (case (:rel rel)
    :scan (let [n (count (:columns (:table rel)))]
            {:op :scan :table (:table rel) :alias (:name rel) :columns (vec (range n)) :width n})
    :query {:op :derived :alias (:name rel) :input (build (:query rel))
            :width (count (:columns rel))}
    :join (let [l (plan-relation (:left rel))
                r (plan-relation (:right rel))]
            {:op :join :kind (:kind rel) :left l :right r :condition (:on rel)
             :width (+ (long (:width l)) (long (:width r)))})))

(defn- sort-keys
  "Sort keys over the projected row (outputs followed by hidden ORDER BY
  expressions)."
  [outputs order-by]
  (let [n-out (count outputs)]
    (loop [items order-by hidden-idx n-out acc []]
      (if-let [item (first items)]
        (let [[idx next-hidden] (if (contains? item :output)
                                  [(:output item) hidden-idx]
                                  [hidden-idx (inc hidden-idx)])
              t (if (< (long idx) n-out) (:type (nth outputs idx)) (:type (:expr item)))]
          (recur (rest items) (long next-hidden)
                 (conj acc {:index idx :type t :desc? (:desc? item)
                            :nulls-first? (:nulls-first? item)})))
        acc))))

(defn- sort-and-limit
  "node below ORDER BY (sort keys ks) and LIMIT/OFFSET, where present."
  [node ks limit offset]
  (let [sorted (if (seq ks) {:op :sort :input node :keys ks :width (:width node)} node)]
    (if (or limit offset)
      {:op :limit :input sorted :limit limit :offset offset :width (:width sorted)}
      sorted)))

(defn- plan-union-all
  "Plan of a bound compound query: the concatenation of the branch plans,
  sorted and limited as a whole (ORDER BY items are output columns)."
  [{:keys [union order-by limit offset columns]}]
  (let [node {:op :union-all :inputs (mapv build union) :width (count columns)}]
    (sort-and-limit node (sort-keys columns order-by) limit offset)))

(defn- plan-select
  [bq]
  (let [{:keys [from where aggregated? group-keys aggregates having outputs distinct?
                order-by limit offset]} bq
        n-out (count outputs)
        base (if from (plan-relation from) {:op :values :rows [[]] :width 0})
        filtered (if where {:op :filter :input base :predicate where :width (:width base)} base)
        agg (if aggregated?
              {:op :aggregate :input filtered :group-keys group-keys :aggregates aggregates
               :width (+ (count group-keys) (count aggregates))}
              filtered)
        having-node (if having {:op :filter :input agg :predicate having :width (:width agg)} agg)
        hidden (vec (keep :expr order-by))
        project {:op :project :input having-node :exprs (into (mapv :expr outputs) hidden)
                 :names (into (mapv :name outputs) (map #(str "_sort" %) (range (count hidden))))
                 :width (+ n-out (count hidden))}
        distinct-node (if distinct? {:op :distinct :input project :width (:width project)} project)
        limited (sort-and-limit distinct-node (sort-keys outputs order-by) limit offset)
        result (if (seq hidden)
                 {:op :project :input limited
                  :exprs (vec (map-indexed (fn [i o] {:node :column :type (:type o) :index i :name (:name o)})
                                           outputs))
                  :names (mapv :name outputs)
                  :width n-out}
                 limited)]
    result))

(defn- build
  "Logical plan of a bound query, subqueries in expressions not yet planned."
  [bq]
  (assoc (if (:union bq) (plan-union-all bq) (plan-select bq)) :columns (:columns bq)))

(defn- plan-subqueries
  "e with the nested query of every subquery expression planned."
  [e]
  (b/transform (fn [x]
                 (if (and (= :subquery (:node x)) (:query x))
                   (assoc x :logical (cond-> (plan-query (:query x))
                                       (= :exists (:kind x)) (assoc :required-outputs #{})))
                   x))
               e))

(defn plan-query
  "Builds the logical plan of a bound query (subqueries included)."
  [bq]
  (walk #(map-exprs plan-subqueries %) (build bq)))

;; ---------------------------------------------------------------------------
;; Debug rendering

(defn- sort-keys-sql [ks]
  (str/join ", " (for [k ks] (str "#" (:index k) (if (:desc? k) " DESC" " ASC")))))

(defn- describe
  [node]
  (case (:op node)
    :values (str "Values rows=" (count (:rows node)))
    :scan (str "Scan " (:name (:table node)) " AS " (:alias node) " columns=" (:columns node))
    :derived (str "Derived " (:alias node))
    :join (str "Join " (name (:kind node))
               (when (:condition node) (str " ON " (b/->sql (:condition node)))))
    :filter (str "Filter " (b/->sql (:predicate node)))
    :aggregate (str "Aggregate keys=[" (str/join ", " (map b/->sql (:group-keys node)))
                    "] aggregates=[" (str/join ", " (map b/aggregate->sql (:aggregates node))) "]")
    :project (str "Project " (str/join ", " (map #(str (b/->sql %1) " AS " %2) (:exprs node) (:names node))))
    :distinct "Distinct"
    :sort (str "Sort " (sort-keys-sql (:keys node)))
    :limit (str "Limit" (when (:limit node) (str " " (b/->sql (:limit node))))
                (when (:offset node) (str " OFFSET " (b/->sql (:offset node)))))
    :union-all "UnionAll"))

(defn format-plan
  "Indented text rendering of a logical plan, for debugging and tests. The
  plans of the subqueries a node evaluates follow its inputs."
  ([plan] (str/join "\n" (format-plan plan 0)))
  ([node ^long depth]
   (let [pad (apply str (repeat (* 2 depth) \space))
         subs (for [e (exprs node) x (b/nodes e) :when (:logical x)]
                [(str pad "  subquery " (name (:kind x)) ":") (:logical x)])]
     (-> [(str pad (describe node))]
         (into (mapcat #(format-plan % (inc depth))) (inputs node))
         (into (mapcat (fn [[title p]] (cons title (format-plan p (+ depth 2))))) subs)))))
