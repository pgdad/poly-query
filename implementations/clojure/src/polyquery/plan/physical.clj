(ns polyquery.plan.physical
  "Physical planning: chooses operator implementations for an (optimized)
  logical plan — hash joins for joins with equality conjuncts between the two
  inputs, nested-loop joins otherwise — and plans the nested queries of
  subquery expressions through the whole pipeline.

  Physical nodes ({:op …}):
    {:op :values :rows [[…]]}
    {:op :table-scan :table T :alias a :columns [i …]}
    {:op :subquery-scan :alias a :input P}
    {:op :filter :input P :predicate e}
    {:op :hash-join :join-type :inner|:left :left P :right P
     :left-keys [k …] :right-keys [k …] :residual e|nil :left-width n :right-width n}
        ; k = {:expr e :cmp-type T}; right key expressions are over the right row
    {:op :nested-loop-join :join-type :inner|:left|:cross :left P :right P
     :condition e|nil :left-width n :right-width n}
    {:op :hash-aggregate :input P :group-keys [e] :aggregates [spec]}
    {:op :project :input P :exprs [e] :names [n]}
    {:op :distinct :input P}
    {:op :sort :input P :keys [{:index :type :desc? :nulls-first?}]}
    {:op :limit :input P :limit e|nil :offset e|nil}
  Subquery expressions carry :plan (a physical plan) instead of :query."
  (:require [polyquery.plan.logical :as logical]
            [polyquery.plan.optimizer :as optimizer]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(declare plan-query)

(defn- plan-expr
  "Plans the nested queries of the subquery expressions in e."
  [options e]
  (when e
    (b/transform (fn [x]
                   (if (and (= :subquery (:node x)) (:query x))
                     (-> x (assoc :plan (plan-query (:query x) options)) (dissoc :query))
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

(defn- plan-join
  [{:keys [kind left right condition]} options phys]
  (let [l (phys left)
        r (phys right)
        lw (long (:width left))
        conjuncts (b/conjuncts (plan-expr options condition))
        keyed (keep #(when-let [k (equi-key % lw)] [% k]) conjuncts)
        base {:left l :right r :left-width lw :right-width (:width right)}]
    (if (or (= kind :cross) (empty? keyed) (= "nested_loop" (:join options)))
      (merge base {:op :nested-loop-join :join-type kind :condition (b/conjoin conjuncts)})
      (let [keyed-set (set (map first keyed))]
        (merge base {:op :hash-join :join-type kind
                     :left-keys (mapv (comp first second) keyed)
                     :right-keys (mapv (comp second second) keyed)
                     :residual (b/conjoin (remove keyed-set conjuncts))})))))

(defn- to-physical
  [node options]
  (let [phys #(to-physical % options)
        px #(plan-expr options %)]
    (case (:op node)
      :values {:op :values :rows (:rows node)}
      :scan {:op :table-scan :table (:table node) :alias (:alias node) :columns (:columns node)}
      :derived {:op :subquery-scan :alias (:alias node) :input (phys (:input node))}
      :join (plan-join node options phys)
      :filter {:op :filter :input (phys (:input node)) :predicate (px (:predicate node))}
      :aggregate {:op :hash-aggregate :input (phys (:input node))
                  :group-keys (mapv px (:group-keys node))
                  :aggregates (mapv #(if (:arg %) (update % :arg px) %) (:aggregates node))}
      :project {:op :project :input (phys (:input node)) :exprs (mapv px (:exprs node))
                :names (:names node)}
      :distinct {:op :distinct :input (phys (:input node))}
      :sort {:op :sort :input (phys (:input node)) :keys (:keys node)}
      :limit {:op :limit :input (phys (:input node)) :limit (px (:limit node))
              :offset (px (:offset node))})))

(defn plan-query
  "Plans a bound query: logical plan → optimization → physical plan.
  options: {:optimize bool (default true), :join \"auto\"|\"hash\"|…}."
  [bq options]
  (let [logical (logical/plan-query bq)
        optimized (if (false? (:optimize options)) logical (optimizer/optimize logical))]
    (assoc (to-physical optimized options) :columns (:columns bq))))
