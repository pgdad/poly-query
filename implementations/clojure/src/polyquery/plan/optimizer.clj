(ns polyquery.plan.optimizer
  "The rule-based logical optimizer (spec/phases/phase-5.md,
  spec/changes/refactor-plan-separation.md). It rewrites logical plans
  (polyquery.plan.logical) only — physical choices belong to
  polyquery.plan.physical — and is a sequence of separately named rules,
  each a function from a logical plan to an equivalent logical plan:

    1. constant-folding    — literal-only expressions → literals, predicate
                             simplification (polyquery.plan.rules.constant-folding)
    2. predicate-pushdown  — filters below joins and renaming projections,
                             into join inputs and conditions
                             (polyquery.plan.rules.predicate-pushdown)
    3. join-reordering     — greedy order of inner-join chains by estimated
                             cardinality (polyquery.plan.rules.join-reordering)
    4. column-pruning      — scans read only referenced columns, unread
                             outputs are not computed
                             (polyquery.plan.rules.column-pruning)

  Every rule handles derived tables and UNION ALL branches itself;
  apply-rule also applies it to the plans of subqueries in expressions.
  `optimize: false` applies no rule."
  (:require [polyquery.plan.logical :as logical]
            [polyquery.plan.rules.column-pruning :as column-pruning]
            [polyquery.plan.rules.constant-folding :as constant-folding]
            [polyquery.plan.rules.join-reordering :as join-reordering]
            [polyquery.plan.rules.predicate-pushdown :as predicate-pushdown]))

(set! *warn-on-reflection* true)

(def rules
  "The optimizer rules in application order."
  [{:name "constant-folding" :rewrite constant-folding/fold-constants}
   {:name "predicate-pushdown" :rewrite predicate-pushdown/pushdown}
   {:name "join-reordering" :rewrite join-reordering/reorder-joins}
   {:name "column-pruning" :rewrite column-pruning/prune-columns}])

(defn rule
  "The rewrite function of the rule named rule-name."
  [rule-name]
  (:rewrite (first (filter #(= rule-name (:name %)) rules))))

(defn apply-rule
  "Applies a rewrite to plan, after applying it to the plans of the
  subqueries in plan's expressions (recursively)."
  [rewrite plan]
  (rewrite (logical/map-subquery-plans #(apply-rule rewrite %) plan)))

(defn optimize
  "Optimizes a logical plan with every rule in order; options :optimize
  false applies none."
  [plan options]
  (if (false? (:optimize options))
    plan
    (reduce (fn [p {:keys [rewrite]}] (apply-rule rewrite p)) plan rules)))
