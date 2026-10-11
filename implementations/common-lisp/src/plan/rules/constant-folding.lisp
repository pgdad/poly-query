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
       (not (bexpr-some (lambda (x)
                          (and (b-op-p x) (eq (b-op-op x) :call)
                               (scalar-function-test-only (b-op-info x))))
                        e))))

(defun fold-constants (e)
  "E with every constant subexpression whose evaluation succeeds replaced by
a literal of the same type."
  (bexpr-rewrite (lambda (x)
                   (when (foldable-p x)
                     (handler-case (make-b-literal (bexpr-type x) (evaluate-constant x))
                       (pq-error () nil))))
                 e))

(defun constant-folding (plan)
  "Rule: fold the constant subexpressions of every expression of PLAN."
  (map-plan-expressions #'fold-constants plan))
