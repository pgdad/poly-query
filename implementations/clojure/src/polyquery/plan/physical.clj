(ns polyquery.plan.physical
  "Physical planning: maps an optimized logical plan (polyquery.plan.logical)
  to physical operators. It alone takes the physical decisions:
    * access paths — index scan (polyquery.plan.access) or table scan with
      row-group skipping; hash lookups for correlated equality predicates;
    * join algorithms — for joins with equality conjuncts between the two
      inputs a hash join built on the smaller input (default and `join:
      auto`/`hash`), a sort-merge join (`join: merge`) or a nested-loop join
      (`join: nested_loop`); nested-loop joins otherwise;
    * top-N for ORDER BY … LIMIT (unless `optimize: false`);
    * SELECT DISTINCT as a hash aggregation without aggregates (except in
      row mode);
    * the execution: `mode` (row / vectorized), `threads` (parallel
      operators, polyquery.plan.parallel) and native kernels, recorded in
      the root's :execution;
  and plans the logical plans of subquery expressions the same way.

  Physical nodes ({:op …}):
    {:op :values :rows [[…]]}
    {:op :table-scan :table T :alias a :columns [i …] :skip [column-predicate …]}
        ; reads only the listed columns (others stay NULL); row groups whose
        ; chunk statistics exclude a :skip predicate are not read
    {:op :index-scan :table T :alias a :columns [i …] :index idx :lookup l
     :predicates [column-predicate …]}
        ; rows found through an index (polyquery.plan.access/choose-index);
        ; always below a filter re-checking the complete predicate
    {:op :subquery-scan :alias a :input P}
    {:op :filter :input P :predicate e}
    {:op :lookup-scan :table T :alias a :columns [i …] :keys [{:expr e :probe e :cmp-type T}]
     :residual e|nil}
        ; scan restricted to rows whose key expressions equal the probe
        ; expressions, which depend only on enclosing queries' rows
        ; (correlated subqueries): executed through a hash table built once
    {:op :hash-join :join-type :inner|:left :left P :right P :build :left|:right
     :left-keys [k …] :right-keys [k …] :residual e|nil :left-width n :right-width n}
        ; k = {:expr e :cmp-type T}; right key expressions are over the right row;
        ; the hash table is built on the :build input
    {:op :merge-join :join-type :inner|:left :left P :right P
     :left-keys [k …] :right-keys [k …] :residual e|nil :left-width n :right-width n}
        ; both inputs sorted on their keys, equal-key runs joined
    {:op :nested-loop-join :join-type :inner|:left|:cross :left P :right P
     :key-condition e|nil :condition e|nil :left-width n :right-width n}
        ; :key-condition (equi-join keys) is tested before :condition
    {:op :hash-aggregate :input P :group-keys [e] :aggregates [spec]}
    {:op :project :input P :exprs [e] :names [n]}
    {:op :distinct :input P}
    {:op :sort :input P :keys [{:index :type :desc? :nulls-first?}]}
    {:op :top-n :input P :keys [...] :limit e :offset e|nil}
        ; ORDER BY … LIMIT: sort keeping only the first LIMIT+OFFSET rows
    {:op :limit :input P :limit e|nil :offset e|nil}
    {:op :union-all :inputs [P …]}
        ; UNION ALL: the rows of every input, input after input
    {:op :gather :input P :partitions n}
        ; parallel execution of a partitionable pipeline (polyquery.plan.parallel)
  :hash-aggregate, :sort and :top-n may carry :partitions n (parallel
  partial aggregation / sorting of a partitionable input).
  Subquery expressions carry :plan (a physical plan) instead of :query and
  :logical. The root of a query plan carries :columns [{:name :type}] and
  :execution {:mode :row|:vectorized :threads n :native? b}."
  (:require [polyquery.plan.access :as access]
            [polyquery.plan.cost :as cost]
            [polyquery.plan.parallel :as parallel]
            [polyquery.sql.bound :as b]
            [polyquery.values :as v])
  (:import (java.util HashSet)))

(set! *warn-on-reflection* true)

(declare plan-tree)

(defn- key-set
  "[keys has-null?]: the keys (values/key-fn from type to cmp-type) of the
  single-column rows, and whether a NULL occurred."
  [rows from cmp-type]
  (let [key-fn (v/key-fn from cmp-type)
        keys (HashSet.)
        has-null? (reduce (fn [has-null? ^objects row]
                            (let [y (aget row 0)]
                              (if (nil? y) true (do (.add keys (key-fn y)) has-null?))))
                          false rows)]
    [keys has-null?]))

(defn- materialize-subquery
  "Replacement of an uncorrelated subquery expression x (with its :plan)
  by its precomputed result: a literal for scalar and EXISTS subqueries, an
  :in-set for IN subqueries. (rows-fn plan) executes a plan (a reducible of
  its rows). A scalar subquery with more than one row is kept, so that its
  error is raised only where execution evaluates it."
  [x rows-fn]
  (let [rows (rows-fn (:plan x))]
    (case (:kind x)
      :scalar (let [rows (into [] (take 2) rows)]
                (if (> (count rows) 1)
                  x
                  {:node :literal :type (:type x)
                   :value (when-let [^objects row (first rows)] (aget row 0))}))
      :exists {:node :literal :type :boolean :value (boolean (seq (into [] (take 1) rows)))}
      :in (let [[keys has-null?] (key-set rows (:type (first (:columns (:plan x)))) (:cmp-type x))]
            {:node :in-set :type :boolean :not? (:not? x) :arg (:arg x) :cmp-type (:cmp-type x)
             :keys keys :has-null? has-null?}))))

(defn- simple-expr? [e] (every? #(#{:literal :column} (:node %)) (b/nodes e)))

(defn- exists-as-in-set
  "An :in-set equivalent to the correlated EXISTS subquery x, or nil. x
  qualifies when its plan projects simple expressions from a lookup scan
  with one key, whose probe reads only the row x is evaluated on and whose
  residual is uncorrelated: EXISTS is then TRUE iff the probe value is
  among the keys of the scanned rows that satisfy the residual (FALSE for a
  NULL probe). Those keys are computed now, by a parallel scan."
  [x rows-fn threads]
  (let [scan (loop [p (:plan x)]
               (if (= :project (:op p))
                 (when (every? simple-expr? (:exprs p)) (recur (:input p)))
                 p))
        [{:keys [expr probe cmp-type]} & more] (:keys scan)
        residual (:residual scan)]
    (when (and (= :lookup-scan (:op scan)) expr (empty? more)
               (every? #(case (:node %)
                          :outer-column (= (:cell %) (:cell x))
                          (:column :subquery) false
                          true)
                       (b/nodes probe))
               (not-any? #(#{:subquery :outer-column} (:node %)) (b/nodes residual)))
      (let [table-scan {:op :table-scan :table (:table scan) :alias (:alias scan)
                        :columns (:columns scan)}
            keys-plan (parallel/parallelize
                       {:op :project :exprs [expr] :names ["key"]
                        :input (if residual
                                 {:op :filter :input table-scan :predicate residual}
                                 table-scan)}
                       threads)
            [keys] (key-set (rows-fn keys-plan) (:type expr) cmp-type)]
        {:node :in-set :type :boolean :exists? true :not? false :cmp-type cmp-type
         :keys keys :has-null? false
         :arg (b/transform #(if (= :outer-column (:node %))
                              (b/column-ref (:index %) (:type %) (:name %))
                              %)
                           probe)}))))

(defn- plan-expr
  "Plans the logical plans of the subquery expressions in e. With the
  option :subquery-rows (see materialize-subquery), uncorrelated subqueries
  and correlated EXISTS subqueries of the form described at
  exists-as-in-set are evaluated now and replaced by their results."
  [options e]
  (when e
    (b/transform (fn [x]
                   (if (and (= :subquery (:node x)) (:logical x))
                     ;; correlated subqueries run once per outer row: serially
                     (let [planned (-> x
                                       (assoc :plan (plan-tree (:logical x)
                                                               (cond-> options
                                                                 (:correlated? x) (assoc :threads 1))))
                                       (dissoc :query :logical))
                           rows-fn (:subquery-rows options)]
                       (cond
                         (nil? rows-fn) planned
                         (not (:correlated? x)) (materialize-subquery planned rows-fn)
                         (= :exists (:kind x)) (or (exists-as-in-set planned rows-fn (:threads options))
                                                   planned)
                         :else planned))
                     x))
                 e)))

(defn- equi-key
  "For a conjunct `l = r` with l over the left input and r over the right
  input (or vice versa), returns [left-key right-key], else nil."
  [e ^long lw]
  (when (and (= :compare (:node e)) (= "=" (:op e))
             (not= :null (:cmp-type e))
             (not (b/correlated? e)))
    (let [side (fn [x]
                 (let [cols (b/column-indices x)]
                   (cond (empty? cols) nil
                         (every? #(< (long %) lw) cols) :left
                         (every? #(>= (long %) lw) cols) :right)))
          {:keys [left right cmp-type]} e
          key (fn [l r] [{:expr l :cmp-type cmp-type}
                         {:expr (b/shift-columns r (- lw)) :cmp-type cmp-type}])]
      (case [(side left) (side right)]
        [:left :right] (key left right)
        [:right :left] (key right left)
        nil))))

(defn- correlated-key
  "For a conjunct `x = y` where x references only the scanned row and y only
  enclosing queries' rows, returns the lookup key, else nil."
  [e]
  (when (and (= :compare (:node e)) (= "=" (:op e))
             (not= :null (:cmp-type e))
             (not-any? #(= :subquery (:node %)) (b/nodes e)))
    (let [inner? #(and (seq (b/column-indices %)) (not-any? (comp #{:outer-column} :node) (b/nodes %)))
          outer? #(and (empty? (b/column-indices %)) (some (comp #{:outer-column} :node) (b/nodes %)))
          {:keys [left right cmp-type]} e]
      (cond
        (and (inner? left) (outer? right)) {:expr left :probe right :cmp-type cmp-type}
        (and (inner? right) (outer? left)) {:expr right :probe left :cmp-type cmp-type}))))

(defn- scan-node
  [{:keys [table alias columns]} skip]
  (cond-> {:op :table-scan :table table :alias alias :columns columns}
    (and (seq skip) (some :chunk-stats (:segments table))) (assoc :skip skip)))

(defn- plan-scan-filter
  "Access path of a filtered base-table scan: an index scan when an index is
  selective enough, else a table scan skipping row groups by statistics.
  The complete predicate is re-checked above either."
  [scan conjuncts options]
  (let [preds (access/column-predicates conjuncts)
        choice (when-not (false? (:use-indexes options))
                 (access/choose-index (:table scan) preds))
        input (if choice
                {:op :index-scan :table (:table scan) :alias (:alias scan) :columns (:columns scan)
                 :index (:index choice) :lookup (:lookup choice) :predicates (:predicates choice)}
                (scan-node scan (access/skip-predicates preds)))]
    {:op :filter :input input :predicate (b/conjoin conjuncts)}))

(defn- plan-filter
  [{:keys [input predicate]} options phys]
  (let [conjuncts (b/conjuncts (plan-expr options predicate))
        keyed (when (= :scan (:op input))
                (keep #(when-let [k (correlated-key %)] [% k]) conjuncts))]
    (cond
      (seq keyed)
      (let [keyed-set (set (map first keyed))]
        {:op :lookup-scan :table (:table input) :alias (:alias input) :columns (:columns input)
         :keys (mapv second keyed)
         :residual (b/conjoin (remove keyed-set conjuncts))})

      (= :scan (:op input)) (plan-scan-filter input conjuncts options)

      :else {:op :filter :input (phys input) :predicate (b/conjoin conjuncts)})))

(defn- plan-join
  [{:keys [kind left right condition]} options phys]
  (let [l (phys left)
        r (phys right)
        lw (long (:width left))
        conjuncts (b/conjuncts (plan-expr options condition))
        keyed (keep #(when-let [k (equi-key % lw)] [% k]) conjuncts)
        keyed-set (set (map first keyed))
        residual (b/conjoin (remove keyed-set conjuncts))
        base {:left l :right r :left-width lw :right-width (:width right)}
        keys {:left-keys (mapv (comp first second) keyed)
              :right-keys (mapv (comp second second) keyed)
              :residual residual}]
    (cond
      (or (= kind :cross) (empty? keyed))
      (merge base {:op :nested-loop-join :join-type kind :condition (b/conjoin conjuncts)})

      (= "nested_loop" (:join options))
      (merge base {:op :nested-loop-join :join-type kind
                   :key-condition (b/conjoin (map first keyed)) :condition residual})

      (= "merge" (:join options))
      (merge base keys {:op :merge-join :join-type kind})

      ;; auto / hash: hash join, built on the smaller input
      :else
      (merge base keys {:op :hash-join :join-type kind
                        :build (if (and (= kind :inner) (< (cost/estimate left) (cost/estimate right)))
                                 :left
                                 :right)}))))

(defn- plan-limit
  [node options phys px]
  (let [input (:input node)]
    (if (and (= :sort (:op input)) (:limit node) (not (false? (:optimize options))))
      {:op :top-n :input (phys (:input input)) :keys (:keys input)
       :limit (px (:limit node)) :offset (px (:offset node))}
      {:op :limit :input (phys input) :limit (px (:limit node)) :offset (px (:offset node))})))

(declare execution-mode)

(defn- plan-distinct
  "SELECT DISTINCT: outside row mode (the baseline's DISTINCT operator), a
  hash aggregation grouping by every column of the projection below it —
  same rows (NULLs grouped together, first appearance order), but
  vectorized and parallelizable."
  [{:keys [input]} options phys]
  (let [in (phys input)]
    (if (and (= :project (:op in)) (not= :row (execution-mode options)))
      {:op :hash-aggregate :input in :aggregates []
       :group-keys (vec (map-indexed (fn [i e] (b/column-ref i (:type e) (nth (:names in) i)))
                                     (:exprs in)))}
      {:op :distinct :input in})))

(defn- to-physical
  [node options]
  (let [phys #(to-physical % options)
        px #(plan-expr options %)]
    (case (:op node)
      :values {:op :values :rows (:rows node)}
      :scan (scan-node node nil)
      :derived {:op :subquery-scan :alias (:alias node) :input (phys (:input node))}
      :join (plan-join node options phys)
      :filter (plan-filter node options phys)
      :aggregate {:op :hash-aggregate :input (phys (:input node))
                  :group-keys (mapv px (:group-keys node))
                  :aggregates (mapv #(if (:arg %) (update % :arg px) %) (:aggregates node))}
      :project {:op :project :input (phys (:input node)) :exprs (mapv px (:exprs node))
                :names (:names node)}
      :distinct (plan-distinct node options phys)
      :sort {:op :sort :input (phys (:input node)) :keys (:keys node)}
      :limit (plan-limit node options phys px)
      :union-all {:op :union-all :inputs (mapv phys (:inputs node))})))

(defn- plan-tree
  "Physical plan of a logical (sub)query plan; options :threads resolved."
  [logical options]
  (assoc (parallel/parallelize (to-physical logical options) (:threads options))
         :columns (:columns logical)))

(def default-threads
  "Worker threads per query when neither the query nor --threads says."
  (min 8 (.availableProcessors (Runtime/getRuntime))))

(defn execution-mode
  "Execution model of a query: `row` (baseline) or `vectorized` (also for
  `auto`, the default)."
  [options]
  (if (#{"row" :row} (:mode options)) :row :vectorized))

(defn- worker-threads
  "Worker threads of a query: its `threads` option, else --threads
  (:default-threads), else default-threads (1 for the row-mode baseline)."
  ^long [options]
  (long (or (:threads options)
            (when (= :row (execution-mode options)) 1)
            (when (pos? (long (or (:default-threads options) 0))) (:default-threads options))
            default-threads)))

(defn plan
  "Physical plan of an optimized logical query plan. options (the query
  options): :optimize bool (default true), :join \"auto\"|\"hash\"|\"merge\"|
  \"nested_loop\", :use-indexes bool (default true), :mode \"auto\"|\"row\"|
  \"vectorized\", :threads n, :default-threads n, :native bool; and, from the
  engine, :subquery-rows (precomputation of uncorrelated subqueries, see
  plan-expr)."
  [logical options]
  (let [mode (execution-mode options)
        threads (worker-threads options)]
    (assoc (plan-tree logical (assoc options :threads threads))
           :execution {:mode mode :threads threads
                       :native? (boolean (and (:native options) (= :vectorized mode)))})))
