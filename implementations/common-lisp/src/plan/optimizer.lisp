;;;; optimizer.lisp — the rule-based logical optimizer.
;;;;
;;;; The optimizer rewrites logical plans only (it knows nothing about access
;;;; paths, join algorithms or execution modes). It is a sequence of named
;;;; rules, each a semantics-preserving function from logical plan to logical
;;;; plan, defined in rules/:
;;;;   :constant-folding          rules/constant-folding.lisp
;;;;   :predicate-simplification  rules/predicate-simplification.lisp
;;;;   :predicate-pushdown        rules/predicate-pushdown.lisp
;;;;   :join-reordering           rules/join-reordering.lisp
;;;;   :column-pruning            rules/column-pruning.lisp
;;;; The rules run once each, in this order, over the plan and over the plans
;;;; of its expression subqueries. With `optimize: false` no rule runs.

(in-package #:polyquery)

(defstruct (optimizer-rule (:constructor make-optimizer-rule (name function)))
  name                                   ; keyword
  function)                              ; logical plan -> logical plan

(defparameter *optimizer-rules*
  (list (make-optimizer-rule :constant-folding #'constant-folding)
        (make-optimizer-rule :predicate-simplification #'predicate-simplification)
        (make-optimizer-rule :predicate-pushdown #'predicate-pushdown)
        (make-optimizer-rule :join-reordering #'join-reordering)
        (make-optimizer-rule :column-pruning #'column-pruning))
  "The rules of the logical optimizer, in the order they are applied.")

(defun find-optimizer-rule (name)
  (or (find name *optimizer-rules* :key #'optimizer-rule-name)
      (error "unknown optimizer rule ~S" name)))

(defun apply-optimizer-rule (name plan)
  "PLAN rewritten by the single rule NAME (not touching subquery plans)."
  (funcall (optimizer-rule-function (find-optimizer-rule name)) plan))

(defun optimize-logical-plan (plan &key (enabled t) (rules *optimizer-rules*))
  "PLAN rewritten by RULES (by default all rules), as are the logical plans
of the expression subqueries it uses. When ENABLED is false (`optimize:
false`), PLAN is returned unchanged."
  (if (not enabled)
      plan
      (let ((done (make-hash-table :test 'eq)))
        (labels ((run (plan)
                   (let ((result (reduce (lambda (p rule) (funcall (optimizer-rule-function rule) p))
                                         rules :initial-value plan)))
                     (map-plan-subqueries
                      (lambda (sq)
                        (unless (gethash sq done)
                          (setf (gethash sq done) t)
                          (setf (subquery-logical-plan sq) (run (subquery-logical-plan sq)))))
                      result)
                     result)))
          (run plan)))))
