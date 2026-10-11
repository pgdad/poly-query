;;;; predicate-pushdown.lisp — optimizer rule PREDICATE-PUSHDOWN.
;;;;
;;;; Splits filter and join conditions into conjuncts and moves each one as
;;;; close to the scans as is valid:
;;;;  * into the inputs of joins (never into the NULL-supplying side of a
;;;;    LEFT JOIN from above) and into the conditions of inner joins, so comma
;;;;    joins become equi-joins;
;;;;  * below Projects (in practice: into derived tables and CTE references)
;;;;    when the projected expressions cannot fail, so evaluating them for
;;;;    fewer rows hides no error: the conjuncts are rewritten over the
;;;;    Project's input by inlining the projected expressions;
;;;;  * through SubqueryAlias nodes.
;;;; Conjuncts from above a node are evaluated after the node's own ones, so
;;;; they are only evaluated for rows that satisfy them (as without pushdown).
;;;; Conjuncts stay above Aggregate, Distinct, Sort, Limit and UnionAll.

(in-package #:polyquery)

(defun predicate-pushdown (plan)
  "Rule: push the filter and join conjuncts of PLAN down."
  (push-down-predicates plan))

(defun push-down-predicates (node)
  (typecase node
    (lp-filter (push-conjuncts (lnode-child node) (split-conjuncts (lp-filter-predicate node))))
    (lp-join (push-conjuncts node '()))
    (t (rebuild-with-children node (mapcar #'push-down-predicates (lnode-children node))))))

(defun push-conjuncts (node conjuncts)
  "Plan NODE with the CONJUNCTS (over NODE's output layout) applied on top,
pushing each conjunct as far down as is valid."
  (typecase node
    (lp-filter
     (push-conjuncts (lnode-child node)
                     (append (split-conjuncts (lp-filter-predicate node)) conjuncts)))
    (lp-join (push-into-join node conjuncts))
    (lp-project (push-into-project node conjuncts))
    (lp-subquery-alias
     (rebuild-with-children node (list (push-conjuncts (lnode-child node) conjuncts))))
    (t (make-filter (push-down-predicates node) (conjoin conjuncts)))))

(defun push-into-join (node conjuncts)
  (destructuring-bind (left right) (lnode-children node)
    (let* ((kind (lp-join-kind node))
           (lw (lnode-width left))
           (width (lnode-width node))
           (outer-join (eq kind :left))
           (to-left '()) (to-right '()) (to-join '()) (above '()))
      ;; Conjuncts of the join's own condition come first, so that (as
      ;; without pushdown) conjuncts from above are only evaluated for rows
      ;; satisfying them.
      ;; Conjuncts without column references (constants, outer references)
      ;; stay above the join: a FALSE one then skips the whole join.
      (dolist (c (and (lp-join-condition node) (split-conjuncts (lp-join-condition node))))
        (cond ((and (not outer-join) (null (bexpr-column-indexes c))) (push c above))
              ((and (not outer-join) (columns-within-p c 0 lw)) (push c to-left))
              ((columns-within-p c lw width) (push c to-right))
              (t (push c to-join))))
      ;; Conjuncts from above the join (WHERE or enclosing filters).
      (dolist (c conjuncts)
        (cond ((null (bexpr-column-indexes c)) (push c above))
              ((columns-within-p c 0 lw) (push c to-left))
              (outer-join (push c above))
              ((columns-within-p c lw width) (push c to-right))
              (t (push c to-join))))
      (let ((join (make-join (if (and (eq kind :cross) to-join) :inner kind)
                             (push-conjuncts left (nreverse to-left))
                             (push-conjuncts right (mapcar (lambda (c) (bexpr-shift-columns c (- lw)))
                                                           (nreverse to-right)))
                             (conjoin (nreverse to-join)))))
        (make-filter join (conjoin (nreverse above)))))))

(defun project-pushdown-valid-p (node)
  "True if filtering the input of the Project NODE instead of its output is
equivalent: its expressions cannot fail and contain no aggregates."
  (notany (lambda (e) (or (may-fail-p e) (bexpr-contains-aggregate-p e)))
          (lp-project-exprs node)))

(defun inline-project-exprs (e exprs)
  "E (over a Project's output) rewritten over the Project's input: every
column reference is replaced by the projected expression EXPRS defines it by."
  (let ((v (coerce exprs 'simple-vector)))
    (bexpr-rewrite (lambda (x) (and (b-column-p x) (svref v (b-column-index x)))) e)))

(defun push-into-project (node conjuncts)
  (if (and conjuncts (project-pushdown-valid-p node))
      (let ((exprs (lp-project-exprs node)))
        (rebuild-with-children node
                               (list (push-conjuncts (lnode-child node)
                                                     (mapcar (lambda (c) (inline-project-exprs c exprs))
                                                             conjuncts)))))
      (make-filter (push-down-predicates node) (conjoin conjuncts))))
