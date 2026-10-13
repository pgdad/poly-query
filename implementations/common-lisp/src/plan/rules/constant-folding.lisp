;;;; constant-folding.lisp — optimizer rule CONSTANT-FOLDING.
;;;;
;;;; Every constant subexpression (literals only: no columns, parameters,
;;;; aggregates or subqueries) is evaluated once at planning time and
;;;; replaced by a literal of the same type. An expression whose evaluation
;;;; fails stays, so the error is raised only if a row evaluates it; calls of
;;;; test-only functions are never folded.

(in-package #:polyquery)

(defun foldable-p (e)
  "True if E is a constant expression worth (and safe) evaluating now."
  (and (b-op-p e)
       (bexpr-constant-p e)
       (not (bexpr-has-p e +prop-test-only+))))

(defun fold-constants (e)
  "E with every constant subexpression whose evaluation succeeds replaced by
a literal of the same type. Folding proceeds bottom-up, so each evaluation
works on already folded operands and the deadline is checked between nodes
(a long chain of constants costs linear time, CR-6); the result is the same
as folding the largest constant subexpressions."
  (labels ((fold (x)
             (check-interrupts)
             (typecase x
               (b-op
                (let* ((args (mapcar #'fold (b-op-args x)))
                       (node (if (every #'eq args (b-op-args x))
                                 x
                                 (make-b-op (bexpr-type x) (b-op-op x) args (b-op-info x)))))
                  (or (and (foldable-p node)
                           (handler-case (make-b-literal (bexpr-type node) (evaluate-constant node))
                             (pq-error (err)
                               (when (interrupt-error-p err) (error err))
                               nil)))
                      node)))
               (b-agg
                (let ((args (mapcar #'fold (b-agg-args x))))
                  (if (every #'eq args (b-agg-args x))
                      x
                      (make-b-agg (bexpr-type x) (b-agg-fn x) args (b-agg-distinct x)))))
               (t x))))
    (fold e)))

(defun constant-folding (plan)
  "Rule: fold the constant subexpressions of every expression of PLAN."
  (map-plan-expressions #'fold-constants plan))
