;;;; predicate-simplification.lisp — optimizer rule PREDICATE-SIMPLIFICATION.
;;;;
;;;; Simplifies boolean structure bottom-up: TRUE/FALSE operands of AND/OR,
;;;; duplicate operands, double negation and negated comparisons. A Filter
;;;; whose predicate becomes TRUE disappears, and so does a join condition
;;;; that becomes TRUE. Best run after CONSTANT-FOLDING, which produces the
;;;; boolean literals.

(in-package #:polyquery)

(defun boolean-literal-p (e value)
  (and (b-literal-p e) (eq (b-literal-value e) value)))

(defun negated-comparison (op)
  (case op (:= :<>) (:<> :=) (:< :>=) (:<= :>) (:> :<=) (:>= :<) (t nil)))

(defun simplify-node (e)
  "Simplify the operator node E whose arguments are already simplified."
  (let ((op (b-op-op e))
        (args (b-op-args e)))
    (case op
      ;; An operand is only dropped when the unoptimized evaluation would not
      ;; evaluate it either (left operand decides) or it cannot fail, so the
      ;; rewrite never hides an error.
      (:and (destructuring-bind (a b) args
              (cond ((boolean-literal-p a t) b)
                    ((boolean-literal-p b t) a)
                    ((boolean-literal-p a nil) a)
                    ((and (boolean-literal-p b nil) (not (may-fail-p a))) b)
                    ((bexpr-equal a b) a)
                    (t e))))
      (:or (destructuring-bind (a b) args
             (cond ((boolean-literal-p a nil) b)
                   ((boolean-literal-p b nil) a)
                   ((boolean-literal-p a t) a)
                   ((and (boolean-literal-p b t) (not (may-fail-p a))) b)
                   ((bexpr-equal a b) a)
                   (t e))))
      (:not (let ((a (first args)))
              (cond ((and (b-op-p a) (eq (b-op-op a) :not)) (first (b-op-args a)))
                    ((and (b-op-p a) (negated-comparison (b-op-op a)))
                     (make-b-op (bexpr-type a) (negated-comparison (b-op-op a)) (b-op-args a)
                                (b-op-info a)))
                    (t e))))
      (t e))))

(defun simplify-expr (e)
  "E with its boolean structure simplified bottom-up."
  (labels ((walk (x)
             (check-interrupts)
             (if (b-op-p x)
                 (let* ((args (mapcar #'walk (b-op-args x)))
                        (node (if (every #'eq args (b-op-args x))
                                  x
                                  (make-b-op (bexpr-type x) (b-op-op x) args (b-op-info x)))))
                   (simplify-node node))
                 x)))
    (walk e)))

(defun drop-true-conditions (node)
  "NODE without Filters whose predicate is TRUE and with TRUE join
conditions removed."
  (let ((children (mapcar #'drop-true-conditions (lnode-children node))))
    (cond ((and (lp-filter-p node) (boolean-literal-p (lp-filter-predicate node) t))
           (first children))
          ((and (lp-join-p node) (boolean-literal-p (lp-join-condition node) t))
           (let ((copy (copy-structure node)))
             (setf (lnode-children copy) children
                   (lp-join-condition copy) nil)
             copy))
          (t (rebuild-with-children node children)))))

(defun predicate-simplification (plan)
  "Rule: simplify every expression of PLAN, then drop TRUE filters and join
conditions."
  (drop-true-conditions (map-plan-expressions #'simplify-expr plan)))
