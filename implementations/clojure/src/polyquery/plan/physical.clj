(ns polyquery.plan.physical
  "Physical planning: chooses operator implementations for an (optimized)
  logical plan — for joins with equality conjuncts between the two inputs a
  hash join (default and `join: auto`/`hash`), a sort-merge join (`join:
  merge`) or a nested-loop join (`join: nested_loop`); nested-loop joins
  otherwise — replaces ORDER BY … LIMIT by a top-N operator (unless
  `optimize: false`), marks parallelizable operators (`threads` > 1,
  polyquery.plan.parallel) and plans the nested queries of subquery
  expressions through the whole pipeline.

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
    {:op :gather :input P :partitions n}
        ; parallel execution of a partitionable pipeline (polyquery.plan.parallel)
  :hash-aggregate, :sort and :top-n may carry :partitions n (parallel
  partial aggregation / sorting of a partitionable input).
  Subquery expressions carry :plan (a physical plan) instead of :query."
  (:require [polyquery.plan.access :as access]
            [polyquery.plan.cost :as cost]
            [polyquery.plan.logical :as logical]
            [polyquery.plan.optimizer :as optimizer]
            [polyquery.plan.parallel :as parallel]
            [polyquery.plan.pruning :as pruning]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(declare plan-query)

(defn- plan-expr
  "Plans the nested queries of the subquery expressions in e."
  [options e]
  (when e
    (b/transform (fn [x]
                   (if (and (= :subquery (:node x)) (:query x))
                     ;; EXISTS only needs to know whether there are rows;
                     ;; correlated subqueries run once per outer row: serially
                     (-> x
                         (assoc :plan (plan-query (:query x) (cond-> options
                                                               (= :exists (:kind x))
                                                               (assoc :required-outputs #{})
                                                               (:correlated? x)
                                                               (assoc :threads 1))))
                         (dissoc :query))
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
      :distinct {:op :distinct :input (phys (:input node))}
      :sort {:op :sort :input (phys (:input node)) :keys (:keys node)}
      :limit (plan-limit node options phys px))))

(defn plan-query
  "Plans a bound query: logical plan → optimization → physical plan.
  options: {:optimize bool (default true), :join \"auto\"|\"hash\"|\"merge\"|
  \"nested_loop\", :use-indexes bool (default true), :threads n (default 1),
  :required-outputs #{i …} (default: all; outputs not in the set are never
  read)}."
  [bq options]
  (let [required (:required-outputs options)
        options (dissoc options :required-outputs)
        logical (logical/plan-query bq)
        optimized (if (false? (:optimize options)) logical (optimizer/optimize logical))
        physical (to-physical (pruning/prune-query optimized required) options)]
    (assoc (parallel/parallelize physical (or (:threads options) 1)) :columns (:columns bq))))
