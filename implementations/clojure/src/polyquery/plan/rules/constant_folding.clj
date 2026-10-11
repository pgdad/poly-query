(ns polyquery.plan.rules.constant-folding
  "Optimizer rule `constant-folding` (spec/phases/phase-5.md): rewrites the
  expressions of a logical plan —

  * constant folding — a row-independent subexpression (no columns,
    correlated references or subqueries, no PQ_SLEEP) is evaluated once at
    planning time and replaced by a literal of the same type. Expressions
    whose evaluation fails are left alone, so the error is raised only if
    the row engine would evaluate them;
  * predicate simplification — TRUE/FALSE operands of AND/OR, double
    negation, duplicate conjuncts, filters whose predicate is TRUE. Only
    rewrites that never skip the evaluation of an operand the row engine
    evaluates are applied (`x AND FALSE` keeps x unless x cannot fail), so
    the result — rows or error — never changes.
  Predicate simplification is folding with partially known operands; it
  runs in the same bottom-up pass, so a predicate it reduces to a literal is
  folded further up."
  (:require [polyquery.exec.expr :as expr]
            [polyquery.sql.bound :as b]))

(set! *warn-on-reflection* true)

(defn- foldable? [e]
  (and (not= :literal (:node e))
       (b/constant? e)
       (not-any? #(= "PQ_SLEEP" (:fn %)) (b/nodes e))))

(defn- fold
  "e, or a literal holding its value when it is constant and evaluates."
  [e]
  (if (foldable? e)
    (try
      {:node :literal :type (:type e)
       :value (expr/eval-constant {:ctx nil :cells (atom {}) :build nil} e)}
      (catch clojure.lang.ExceptionInfo _ e))
    e))

(defn- literal? [e v] (and (= :literal (:node e)) (= :boolean (:type e)) (= v (:value e))))

(defn- infallible?
  "True when evaluating e can never raise an error."
  [e]
  (every? #(case (:node %)
             (:literal :column :outer-column :compare :and :or :not :is-null) true
             false)
          (b/nodes e)))

(defn- simplify-node
  "One step of AND/OR/NOT simplification (children already simplified)."
  [e]
  (case (:node e)
    :and (let [{l :left r :right} e]
           (cond
             (literal? l true) r
             (literal? r true) l
             (literal? l false) l
             (and (literal? r false) (infallible? l)) r
             (= l r) l
             :else e))
    :or (let [{l :left r :right} e]
          (cond
            (literal? l false) r
            (literal? r false) l
            (literal? l true) l
            (and (literal? r true) (infallible? l)) r
            (= l r) l
            :else e))
    :not (let [a (:arg e)]
           (if (= :not (:node a)) (:arg a) e))
    e))

(defn simplify
  "Folds constants and simplifies predicates in expression e (nil-safe)."
  [e]
  (when e (b/transform (comp simplify-node fold) e)))

(defn- simplify-conjunction
  "Simplified predicate with duplicate conjuncts removed; nil if TRUE."
  [p]
  (let [cs (distinct (b/conjuncts (simplify p)))
        cs (remove #(literal? % true) cs)]
    (b/conjoin cs)))

(defn fold-constants
  "The rule: applies the rewrites to the expressions of a logical plan
  (derived tables and UNION ALL branches included)."
  [node]
  (let [rec fold-constants]
    (case (:op node)
      :filter (let [input (rec (:input node))
                    p (simplify-conjunction (:predicate node))]
                (if p (assoc node :input input :predicate p) input))
      :join (-> node
                (update :left rec)
                (update :right rec)
                (assoc :condition (simplify-conjunction (:condition node))))
      :aggregate (-> node
                     (update :input rec)
                     (update :group-keys #(mapv simplify %))
                     (update :aggregates #(mapv (fn [a] (if (:arg a) (update a :arg simplify) a)) %)))
      :project (-> node (update :input rec) (update :exprs #(mapv simplify %)))
      (:distinct :sort :limit :derived) (update node :input rec)
      :union-all (update node :inputs #(mapv rec %))
      node)))
