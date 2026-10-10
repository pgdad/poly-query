;;;; bound.lisp — bound (resolved and typed) expressions produced by the binder.
;;;;
;;;; Three node kinds keep tree walking uniform:
;;;;   B-LITERAL  constant value of a static type
;;;;   B-COLUMN   reference to position INDEX of the operator's input row
;;;;   B-OP       operator/function application: OP keyword, ARGS list and
;;;;              op-specific INFO (e.g. the function descriptor)
;;;;   B-AGG      aggregate call (only before aggregation is planned)

(in-package #:polyquery)

(defstruct (bexpr (:constructor nil))
  type)

(defstruct (b-literal (:include bexpr) (:constructor make-b-literal (type value)))
  value)

(defstruct (b-column (:include bexpr) (:constructor make-b-column (type index name)))
  (index 0 :type fixnum)
  name)

(defstruct (b-op (:include bexpr) (:constructor make-b-op (type op args &optional info)))
  op args info)

(defstruct (b-agg (:include bexpr) (:constructor make-b-agg (type fn args distinct)))
  fn args distinct)

(defun bexpr-children (e)
  (typecase e
    (b-op (b-op-args e))
    (b-agg (b-agg-args e))
    (t nil)))

(defun bexpr-some (predicate e)
  "True if PREDICATE holds for E or any of its subexpressions."
  (or (funcall predicate e)
      (some (lambda (c) (bexpr-some predicate c)) (bexpr-children e))))

(defun bexpr-walk (fn e)
  "Call FN on every node of E (pre-order)."
  (funcall fn e)
  (dolist (c (bexpr-children e)) (bexpr-walk fn c)))

(defun bexpr-contains-aggregate-p (e)
  (bexpr-some #'b-agg-p e))

(defun bexpr-constant-p (e)
  (not (bexpr-some (lambda (x) (or (b-column-p x) (b-agg-p x))) e)))

(defun bexpr-equal (a b)
  "Structural equality: same operators, literal values, column bindings and types."
  (cond ((and (b-literal-p a) (b-literal-p b))
         (and (type-equal (bexpr-type a) (bexpr-type b))
              (equal (b-literal-value a) (b-literal-value b))))
        ((and (b-column-p a) (b-column-p b))
         (= (b-column-index a) (b-column-index b)))
        ((and (b-op-p a) (b-op-p b))
         (and (eq (b-op-op a) (b-op-op b))
              (equal (b-op-info a) (b-op-info b))
              (type-equal (bexpr-type a) (bexpr-type b))
              (= (length (b-op-args a)) (length (b-op-args b)))
              (every #'bexpr-equal (b-op-args a) (b-op-args b))))
        ((and (b-agg-p a) (b-agg-p b))
         (and (eq (b-agg-fn a) (b-agg-fn b))
              (eq (b-agg-distinct a) (b-agg-distinct b))
              (= (length (b-agg-args a)) (length (b-agg-args b)))
              (every #'bexpr-equal (b-agg-args a) (b-agg-args b))))
        (t nil)))

(defun bexpr-rewrite (fn e)
  "Rebuild E top-down: FN returns a replacement node or NIL to descend."
  (or (funcall fn e)
      (typecase e
        (b-op (make-b-op (bexpr-type e) (b-op-op e)
                         (mapcar (lambda (c) (bexpr-rewrite fn c)) (b-op-args e))
                         (b-op-info e)))
        (b-agg (make-b-agg (bexpr-type e) (b-agg-fn e)
                           (mapcar (lambda (c) (bexpr-rewrite fn c)) (b-agg-args e))
                           (b-agg-distinct e)))
        (t e))))

(defun bexpr-remap-columns (e mapping)
  "Copy of E with every column index I replaced by (funcall MAPPING I)."
  (bexpr-rewrite (lambda (x)
                   (when (b-column-p x)
                     (make-b-column (bexpr-type x) (funcall mapping (b-column-index x))
                                    (b-column-name x))))
                 e))

(defun bexpr-column-indexes (e)
  "List of distinct column indexes referenced by E."
  (let ((acc '()))
    (bexpr-walk (lambda (x) (when (b-column-p x) (pushnew (b-column-index x) acc))) e)
    acc))

(defun bexpr-describe (e)
  "Compact human-readable rendering (used by EXPLAIN and error messages)."
  (typecase e
    (b-literal (if (null-value-p (b-literal-value e))
                   "NULL"
                   (value-to-text (b-literal-value e) (bexpr-type e))))
    (b-column (or (b-column-name e) (format nil "#~D" (b-column-index e))))
    (b-op (format nil "~(~A~)(~{~A~^, ~})" (b-op-op e) (mapcar #'bexpr-describe (b-op-args e))))
    (b-agg (format nil "~(~A~)(~:[~;DISTINCT ~]~{~A~^, ~})" (b-agg-fn e) (b-agg-distinct e)
                   (mapcar #'bexpr-describe (b-agg-args e))))
    (t "?")))
