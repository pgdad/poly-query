(ns polyquery.plan.cost
  "Cardinality estimation over logical plans (spec/storage/indexes-and-planning.md
  §3.4), used to pick the build side of hash joins. Filters over base-table
  scans are estimated from table statistics (column predicates); other
  conjuncts are assumed to keep half of the rows."
  (:require [polyquery.plan.access :as access]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(def ^:private default-selectivity 0.5)

(declare estimate)

(defn- filter-estimate
  [{:keys [input predicate]}]
  (let [rows (double (estimate input))
        conjuncts (b/conjuncts predicate)]
    (if (= :scan (:op input))
      (let [preds (access/column-predicates conjuncts)
            covered (set (map :sql preds))
            others (remove #(contains? covered (b/->sql %)) conjuncts)]
        (* rows
           (double (reduce * 1.0 (map #(access/predicate-selectivity (:table input) %) preds)))
           (Math/pow default-selectivity (count others))))
      (* rows (Math/pow default-selectivity (count conjuncts))))))

(defn estimate
  "Estimated number of rows produced by a logical plan node."
  ^double [node]
  (double
   (case (:op node)
     :scan (:row-count (:table node))
     :values (count (:rows node))
     :derived (estimate (:input node))
     :filter (filter-estimate node)
     :join (let [l (estimate (:left node))
                 r (estimate (:right node))]
             (if (or (= :cross (:kind node)) (nil? (:condition node)))
               (* l r)
               (max l r)))
     :union-all (reduce + 0.0 (map estimate (:inputs node)))
     :aggregate (if (seq (:group-keys node)) (max 1.0 (* 0.1 (estimate (:input node)))) 1.0)
     :limit (let [n (estimate (:input node))
                  lim (:limit node)]
              (if (= :literal (:node lim)) (min n (double (or (:value lim) n))) n))
     (estimate (:input node)))))
