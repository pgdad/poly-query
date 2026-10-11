(ns polyquery.plan.rules.predicate-pushdown
  "Optimizer rule `predicate-pushdown` (spec/storage/indexes-and-planning.md
  §3.1): WHERE conjuncts and ON conjuncts are moved as close to the scans as
  their column references allow; WHERE conjuncts spanning both sides of an
  inner/cross join become join conditions (enabling equi-joins). A filter
  over a projection that only renames or reorders columns (as join
  reordering creates) moves below it.

  Conjuncts containing correlated subqueries are never moved: their
  subqueries read the row they are evaluated on, which must keep the layout
  it was bound against."
  (:require [polyquery.plan.logical :as logical]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(declare pushdown push-down)

(defn- with-filter [node preds]
  (if (seq preds)
    {:op :filter :input node :predicate (b/conjoin preds) :width (:width node)}
    node))

(defn- side
  "Which input of a join with left width lw the predicate references:
  :left, :right, :both or :none."
  [e ^long lw]
  (let [cols (b/column-indices e)]
    (cond (empty? cols) :none
          (every? #(< (long %) lw) cols) :left
          (every? #(>= (long %) lw) cols) :right
          :else :both)))

(defn- movable? [e] (not (b/correlated? e)))

(defn- push-into-join
  [{:keys [kind left right condition] :as node} preds]
  (let [lw (long (:width left))
        to-right #(b/shift-columns % (- lw))
        on (b/conjuncts condition)]
    (if (= kind :left)
      ;; WHERE conjuncts may only move to the preserved (left) side; ON
      ;; conjuncts referencing only the right side filter the right input.
      (let [lp (filter #(and (movable? %) (= :left (side % lw))) preds)
            above (remove (set lp) preds)
            rp (filter #(and (movable? %) (= :right (side % lw))) on)
            on' (remove (set rp) on)]
        (with-filter (assoc node
                            :left (push-down left (vec lp))
                            :right (push-down right (mapv to-right rp))
                            :condition (b/conjoin on'))
          (vec above)))
      (let [all (concat on preds)
            fixed-where (remove movable? preds)
            movable (concat (filter movable? on) (filter movable? preds))
            by-side (group-by #(side % lw) movable)
            lp (concat (:none by-side) (:left by-side))
            rp (map to-right (:right by-side))
            join-cond (concat (remove movable? on) (:both by-side))]
        (assert (= (count all) (+ (count fixed-where) (count lp) (count rp) (count join-cond))))
        (with-filter (assoc node
                            :kind (if (and (= kind :cross) (seq join-cond)) :inner kind)
                            :left (push-down left (vec lp))
                            :right (push-down right (vec rp))
                            :condition (b/conjoin join-cond))
          (vec fixed-where))))))

(defn- push-down
  "Places predicates over node's output row as low as possible below node,
  a FROM-clause node."
  [node preds]
  (case (:op node)
    :join (push-into-join node preds)
    :derived (with-filter (update node :input pushdown) preds)
    (with-filter node preds)))

(defn- from-node? [node] (#{:scan :values :derived :join} (:op node)))

(defn- renaming?
  "True when the projection's expressions are column references and
  literals: they cannot fail, so filtering first changes no result."
  [node]
  (and (= :project (:op node)) (every? #(#{:column :literal} (:node %)) (:exprs node))))

(defn- below-projection
  "Predicate over a projection's output rewritten over its input."
  [e exprs]
  (b/transform #(if (= :column (:node %)) (nth exprs (:index %)) %) e))

(defn pushdown
  "The rule: predicate pushdown over a logical plan (derived tables and
  UNION ALL branches included)."
  [node]
  (cond
    (and (= :filter (:op node)) (from-node? (:input node)))
    (push-down (:input node) (b/conjuncts (:predicate node)))

    (from-node? node) (push-down node [])

    (and (= :filter (:op node)) (renaming? (:input node)))
    (let [{:keys [input exprs] :as project} (:input node)
          {movable true fixed false} (group-by movable? (b/conjuncts (:predicate node)))]
      (with-filter (assoc project :input (pushdown (with-filter input (map #(below-projection % exprs) movable))))
        fixed))

    :else (logical/map-inputs pushdown node)))
