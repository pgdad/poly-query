(ns polyquery.plan.rules.join-reordering
  "Optimizer rule `join-reordering`: reorders chains of inner/cross joins
  (spec/phases/phase-5.md).

  A maximal tree of INNER/CROSS joins is flattened into its relations and
  the conjuncts of its join conditions (after predicate pushdown). The
  relations are re-joined greedily as a left-deep tree: starting with the
  smallest estimated input (polyquery.plan.cost), repeatedly the smallest
  relation connected to the joined ones by a condition — a cross product
  only when no relation is connected. Each conjunct is placed at the lowest
  join where all its columns are available. A projection on top restores
  the original column order, which the rest of the plan addresses.

  Clusters whose conditions contain subqueries are left alone (subqueries
  may read the row through correlation by position), as are LEFT joins
  (they are cluster boundaries) and clusters already in greedy order."
  (:require [polyquery.plan.cost :as cost]
            [polyquery.plan.logical :as logical]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(declare reorder-joins)

(defn- inner? [node] (and (= :join (:op node)) (#{:inner :cross} (:kind node))))

(defn- flatten-cluster
  "[relations conjuncts] of the inner-join tree `node` whose row starts at
  `base` in the cluster row. A relation is {:node n :offset o :width w}."
  [node ^long base]
  (if (inner? node)
    (let [lw (long (:width (:left node)))
          [lr lc] (flatten-cluster (:left node) base)
          [rr rc] (flatten-cluster (:right node) (+ base lw))]
      [(into lr rr)
       (-> (into lc rc)
           (into (map #(b/shift-columns % base)) (b/conjuncts (:condition node))))])
    [[{:node (reorder-joins node) :offset base :width (long (:width node))}] []]))

(defn- column-types
  "[[name type] …] of the columns of a FROM-clause node."
  [node]
  (case (:op node)
    :scan (mapv (fn [c] [(:name c) (:type c)]) (:columns (:table node)))
    :derived (mapv (fn [c] [(:name c) (:type c)]) (:columns (:input node)))
    :join (into (column-types (:left node)) (column-types (:right node)))
    :values []
    (column-types (:input node))))

(defn- rels-of
  "Indices of the relations whose columns conjunct c references."
  [rels c]
  (set (for [col (b/column-indices c)
             [i r] (map-indexed vector rels)
             :when (and (>= (long col) (long (:offset r)))
                        (< (long col) (+ (long (:offset r)) (long (:width r)))))]
         i)))

(defn- greedy-order
  "Join order (vector of relation indices) for the relations and the sets
  of relations each conjunct connects."
  [ests conj-rels]
  (let [n (count ests)
        ;; ties: the relation first in FROM order
        smallest (fn [cands] (apply min-key #(nth ests %) (reverse (sort cands))))]
    (loop [order [(smallest (range n))]]
      (if (= n (count order))
        order
        (let [joined (set order)
              remaining (remove joined (range n))
              connected (filter (fn [r] (some #(and (contains? % r) (every? (conj joined r) %)
                                                    (some joined %))
                                              conj-rels))
                                remaining)]
          (recur (conj order (smallest (if (seq connected) connected remaining)))))))))

(defn- rebuild
  "Left-deep join tree of the relations in `order` with the conjuncts
  placed, topped by a projection restoring the original column order."
  [rels conjs conj-rels order types]
  (let [new-offsets (loop [os {} off 0 [r & more] order]
                      (if (nil? r) os (recur (assoc os r off) (+ off (long (:width (nth rels r)))) more)))
        remap (fn [^long col]
                (let [r (first (keep-indexed (fn [i rel] (when (and (>= col (long (:offset rel)))
                                                                     (< col (+ (long (:offset rel)) (long (:width rel)))))
                                                            i))
                                             rels))]
                  (+ (- col (long (:offset (nth rels r)))) (long (new-offsets r)))))
        moved (mapv (fn [c] (b/transform #(if (= :column (:node %)) (update % :index remap) %) c)) conjs)
        tree (loop [[r & more] (rest order)
                    acc (:node (nth rels (first order)))
                    placed #{(first order)}
                    pending (set (range (count conjs)))]
               (if (nil? r)
                 (if (seq pending)
                   ;; constant conjuncts (no columns) end up here
                   {:op :filter :input acc :predicate (b/conjoin (map moved (sort pending)))
                    :width (:width acc)}
                   acc)
                 (let [placed (conj placed r)
                       here (filter #(every? placed (nth conj-rels %)) (sort pending))
                       rel (:node (nth rels r))
                       cond (b/conjoin (map moved here))]
                   (recur more
                          {:op :join :kind (if cond :inner :cross) :left acc :right rel :condition cond
                           :width (+ (long (:width acc)) (long (:width rel)))}
                          placed
                          (reduce disj pending here)))))
        width (reduce + (map :width rels))]
    {:op :project :input tree
     :exprs (vec (for [col (range width)
                       :let [[cname ctype] (nth types col)]]
                   {:node :column :index (remap col) :type ctype :name cname}))
     :names (mapv first types)
     :width width}))

(defn- recurse-leaves
  "The inner-join tree with only its relations (non-inner-join nodes)
  optimized."
  [node]
  (if (inner? node)
    (-> node (update :left recurse-leaves) (update :right recurse-leaves))
    (reorder-joins node)))

(defn- reorder-cluster [node]
  (let [[rels conjs] (flatten-cluster node 0)
        conj-rels (mapv #(rels-of rels %) conjs)]
    (if (or (< (count rels) 3)
            (some (fn [c] (some #(= :subquery (:node %)) (b/nodes c))) conjs))
      ;; two relations: the hash join already builds on the smaller one
      (recurse-leaves node)
      (let [order (greedy-order (mapv #(cost/estimate (:node %)) rels) conj-rels)]
        (if (= order (vec (range (count rels))))
          (recurse-leaves node)
          (rebuild rels conjs conj-rels order (column-types node)))))))

(defn reorder-joins
  "The rule: reorders the inner-join clusters of a logical plan (derived
  tables and UNION ALL branches included, before the clusters containing
  them are estimated)."
  [node]
  (if (inner? node)
    (reorder-cluster node)
    (logical/map-inputs reorder-joins node)))
