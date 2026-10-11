;;;; builder.lisp — build logical plans (logical.lisp) from analysed queries.
;;;;
;;;; Shape for a SELECT:
;;;;   FROM tree (Scan / Join / SubqueryAlias over derived plans) or Values
;;;;     -> [Filter WHERE] -> [Aggregate -> [Filter HAVING]]
;;;;     -> Project(outputs + hidden sort keys) -> [Distinct] -> [Sort]
;;;;     -> [Limit] -> [Project(strip hidden keys)]
;;;; A UNION ALL compound's FROM is a UnionAll node whose children are the
;;;; branch plans, each topped by a Project converting it to the common types.
;;;;
;;;; BUILD-LOGICAL-PLAN returns plans whose scans read only the columns the
;;;; query references (indexes-and-planning.md §3 requires column pruning
;;;; regardless of the `optimize` option, so it is part of building the plan;
;;;; the column-pruning rule repeats it after other rewrites), and builds the
;;;; plans of the expression subqueries used by the plan.

(in-package #:polyquery)

(defun plan-from (bf)
  "Logical plan producing the FROM row of the BF-* subtree."
  (etypecase bf
    (bf-table
     (let ((table (bf-table-table bf)))
       (make-scan table (relation-name (bf-table-relation bf))
                  (loop for i below (table-column-count table) collect i))))
    (bf-derived (make-subquery-alias (plan-query (bf-derived-query bf))
                                     (relation-name (bf-derived-relation bf))
                                     :cte (bf-derived-cte bf)))
    (bf-union
     (let ((columns (bf-union-columns bf)))
       (make-union-all (mapcar (lambda (branch) (plan-union-branch branch columns))
                               (bf-union-branches bf))
                       columns)))
    (bf-join
     (make-join (bf-join-kind bf)
                (plan-from (bf-join-left bf))
                (plan-from (bf-join-right bf))
                (and (bf-join-condition bf)
                     (bexpr-shift-columns (bf-join-condition bf) (- (bf-node-offset bf))))))))

(defun plan-union-branch (bq columns)
  "Plan of a UNION ALL branch converted to the COLUMNS of the compound: the
casts to the common types (and the compound's names) go into the branch's
final Project, or into a Project above it when it ends in a Distinct (which
must compare the branch's own values)."
  (let ((node (plan-query bq))
        (names (mapcar #'column-def-name columns))
        (types (mapcar #'column-def-type columns)))
    (if (lp-project-p node)
        (make-project (lnode-child node)
                      (mapcar #'implicit-cast (lp-project-exprs node) types)
                      names)
        (make-project node
                      (loop for c in (lnode-columns node)
                            for type in types
                            for i from 0
                            collect (implicit-cast (make-b-column (column-def-type c) i
                                                                  (column-def-name c))
                                                   type))
                      names))))

(defun plan-query (bq)
  "The unpruned logical plan of the BOUND-QUERY BQ (without the plans of its
expression subqueries)."
  (let* ((node (if (bound-query-from bq)
                   (plan-from (bound-query-from bq))
                   (make-lp-values)))
         (outputs (bound-query-outputs bq))
         (hidden (bound-query-hidden bq))
         (names (mapcar #'column-def-name (bound-query-columns bq))))
    (setf node (make-filter node (bound-query-where bq)))
    (when (bound-query-aggregated-p bq)
      (setf node (make-filter (make-aggregate node (bound-query-group-by bq)
                                              (bound-query-aggregates bq))
                              (bound-query-having bq))))
    ;; A UNION ALL compound's outputs are exactly its FROM row.
    (unless (bf-union-p (bound-query-from bq))
      (setf node (make-project node (append outputs hidden)
                               (append names (mapcar #'bexpr-describe hidden)))))
    (when (bound-query-distinct bq)
      (setf node (make-distinct node)))
    (when (bound-query-order bq)
      (let ((all (append outputs hidden)))
        (setf node (make-sort node
                              (loop for (pos desc nulls-first) in (bound-query-order bq)
                                    collect (list pos (bexpr-type (nth pos all)) desc nulls-first))))))
    (when (or (bound-query-limit bq) (bound-query-offset bq))
      (setf node (make-limit node (bound-query-limit bq) (bound-query-offset bq))))
    (when hidden
      (setf node (make-project node
                               (loop for e in outputs
                                     for name in names
                                     for i from 0
                                     collect (make-b-column (bexpr-type e) i name))
                               names)))
    node))

(defun build-logical-plan (bq)
  "The logical plan of the BOUND-QUERY BQ: its scans read only referenced
columns, and every expression subquery it uses carries its own logical plan."
  (let ((plan (prune-columns (plan-query bq))))
    (map-plan-subqueries (lambda (sq)
                           (unless (subquery-logical-plan sq)
                             (setf (subquery-logical-plan sq)
                                   (build-logical-plan (subquery-query sq)))))
                         plan)
    plan))
