;;;; bound.lisp — bound (resolved and typed) expressions produced by the binder.
;;;;
;;;; Node kinds keep tree walking uniform:
;;;;   B-LITERAL  constant value of a static type
;;;;   B-COLUMN   reference to position INDEX of the operator's input row
;;;;   B-PARAM    reference to a correlation parameter of the enclosing
;;;;              subquery (an outer-query value, constant per evaluation)
;;;;   B-OP       operator/function application: OP keyword, ARGS list and
;;;;              op-specific INFO (function descriptor, SUBQUERY, ...)
;;;;   B-AGG      aggregate call (only before aggregation is planned)

(in-package #:polyquery)

(defstruct (bexpr (:constructor nil))
  type)

(defstruct (b-literal (:include bexpr) (:constructor make-b-literal (type value)))
  value)

(defstruct (b-column (:include bexpr) (:constructor make-b-column (type index name)))
  (index 0 :type fixnum)
  name)

(defstruct (param-env (:constructor make-param-env ()))
  "Runtime cell holding the current correlation parameter values of one
subquery; set before each evaluation of the subquery."
  (values #() :type simple-vector))

(defstruct (b-param (:include bexpr) (:constructor make-b-param (type env index name)))
  env
  (index 0 :type fixnum)
  name)

(defstruct (b-op (:include bexpr) (:constructor make-b-op (type op args &optional info)))
  op args info)

(defstruct (b-agg (:include bexpr) (:constructor make-b-agg (type fn args distinct)))
  fn args distinct)

(defstruct scalar-function
  "A scalar function of the registry (functions.lisp); INFO of a :CALL B-OP."
  name
  (min-args 0) (max-args 0)
  typer
  builder
  (null-aware nil)
  (test-only nil))

(defstruct subquery
  "Descriptor of a subquery used as an expression (INFO of a :SUBQUERY B-OP).
The B-OP's ARGS are the IN operand (for :IN) followed by the correlation
parameter expressions, which are evaluated in the enclosing row."
  kind                                  ; :SCALAR, :EXISTS or :IN
  query                                 ; BOUND-QUERY
  (param-env (make-param-env))
  (param-count 0)
  (cacheable t)                         ; NIL if results depend on foreign parameters
  plan)                                 ; physical plan, filled in by the planner

(defun subquery-op-p (e)
  (and (b-op-p e) (eq (b-op-op e) :subquery)))

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
  "True if E depends on nothing but literals (no columns, parameters,
aggregates or subqueries)."
  (not (bexpr-some (lambda (x) (or (b-column-p x) (b-agg-p x) (b-param-p x) (subquery-op-p x)))
                   e)))

(defun bexpr-equal (a b)
  "Structural equality: same operators, literal values, column bindings and types."
  (cond ((and (b-literal-p a) (b-literal-p b))
         (and (type-equal (bexpr-type a) (bexpr-type b))
              (equal (b-literal-value a) (b-literal-value b))))
        ((and (b-column-p a) (b-column-p b))
         (= (b-column-index a) (b-column-index b)))
        ((and (b-param-p a) (b-param-p b))
         (and (eq (b-param-env a) (b-param-env b))
              (= (b-param-index a) (b-param-index b))))
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

(defun bexpr-shift-columns (e delta)
  "Copy of E with every column index increased by DELTA."
  (if (zerop delta) e (bexpr-remap-columns e (lambda (i) (+ i delta)))))

(defun bexpr-column-indexes (e)
  "List of distinct column indexes referenced by E."
  (let ((acc '()))
    (bexpr-walk (lambda (x) (when (b-column-p x) (pushnew (b-column-index x) acc))) e)
    acc))

(defun split-conjuncts (e)
  "Flatten a tree of ANDs into the list of its conjuncts."
  (if (and (b-op-p e) (eq (b-op-op e) :and))
      (mapcan #'split-conjuncts (copy-list (b-op-args e)))
      (list e)))

(defun conjoin (conjuncts)
  "Inverse of SPLIT-CONJUNCTS: AND the CONJUNCTS together (NIL if none)."
  (when conjuncts
    (reduce (lambda (a b) (make-b-op :boolean :and (list a b))) conjuncts)))

;;; ------------------------------------------------------------------
;;; Failure analysis: which expressions can signal an error for some row
;;; (used to keep evaluation lazy where it matters, and by the optimizer)

(defun safe-cast-p (from to)
  (or (type-equal from to)
      (null-type-p from)
      (and (member (type-kind from) '(:int64 :decimal)) (eq (type-kind to) :float64))))

(defun mixes-int-and-decimal-p (exprs)
  "True if EXPRS include both INT64 and DECIMAL operands whose comparison may
overflow: the INT64 operand is promoted to DECIMAL(18,s), which fails for
values of more than 18-s digits (types.md §2). Literals are checked now."
  (let* ((decimals (remove-if-not #'decimal-type-p exprs :key #'bexpr-type))
         (scale (reduce #'max decimals :key (lambda (e) (decimal-scale (bexpr-type e)))
                                       :initial-value 0)))
    (and decimals
         (some (lambda (e)
                 (and (eq (type-kind (bexpr-type e)) :int64)
                      (not (and (b-literal-p e)
                                (let ((v (b-literal-value e)))
                                  (or (eq v +null+)
                                      (fits-precision-p (* v (pow10 scale))
                                                        +max-decimal-precision+)))))))
               exprs))))

(defun node-may-fail-p (e)
  (and (b-op-p e)
       (case (b-op-op e)
         ((:+ :- :* :/ :% :neg :call :subquery) t)
         (:cast (not (safe-cast-p (bexpr-type (first (b-op-args e))) (bexpr-type e))))
         ((:= :<> :< :<= :> :>= :between :in-list :case) (mixes-int-and-decimal-p (b-op-args e)))
         (t nil))))

(defun may-fail-p (e)
  "True if evaluating E can signal an error for some row."
  (bexpr-some #'node-may-fail-p e))

;;; ------------------------------------------------------------------
;;; Analysed query representation

(defstruct bound-query
  "A fully analysed query. Input-side expressions (WHERE, join conditions,
GROUP BY, aggregate arguments) index the FROM row: the concatenation of the
columns of all range variables in FROM order. Output-side expressions
(OUTPUTS, HIDDEN, HAVING) index the FROM row, or — when AGGREGATED-P — the
aggregation row [group keys..., aggregate values...]."
  from                     ; BF-* tree or NIL (SELECT without FROM)
  (from-width 0)
  where                    ; BEXPR or NIL
  aggregated-p
  group-by                 ; list of BEXPR
  aggregates               ; list of B-AGG
  having                   ; BEXPR or NIL
  outputs                  ; list of BEXPR, one per result column
  hidden                   ; list of BEXPR: extra sort keys after the outputs
  distinct
  order                    ; list of (position descending nulls-first)
  limit offset             ; constant BEXPRs or NIL
  columns)                 ; list of COLUMN-DEF describing the result

(defstruct (bf-node (:constructor nil))
  relation-list            ; RELATIONs of this subtree, in FROM order
  (offset 0)               ; position of the subtree's first column in the FROM row
  (width 0))

(defstruct (bf-table (:include bf-node))
  relation table)

(defstruct (bf-derived (:include bf-node))
  relation query)

(defstruct (bf-join (:include bf-node))
  kind left right condition)   ; kind :INNER :LEFT :CROSS; condition over the FROM row

;;; ------------------------------------------------------------------
;;; Rendering (EXPLAIN and error messages)

(defparameter *infix-operators*
  '((:+ . "+") (:- . "-") (:* . "*") (:/ . "/") (:% . "%") (:concat . "||")
    (:= . "=") (:<> . "<>") (:< . "<") (:<= . "<=") (:> . ">") (:>= . ">=")
    (:and . "AND") (:or . "OR")))

(defun bexpr-describe (e)
  "Compact SQL-like rendering of a bound expression."
  (typecase e
    (b-literal (cond ((null-value-p (b-literal-value e)) "NULL")
                     ((member (type-kind (bexpr-type e)) '(:string :date :timestamp))
                      (format nil "'~A'" (value-to-text (b-literal-value e) (bexpr-type e))))
                     (t (value-to-text (b-literal-value e) (bexpr-type e)))))
    (b-column (or (b-column-name e) (format nil "#~D" (b-column-index e))))
    (b-param (format nil "outer.~A" (or (b-param-name e) (b-param-index e))))
    (b-op
     (let ((op (b-op-op e))
           (args (mapcar #'bexpr-describe (b-op-args e))))
       (cond
         ((assoc op *infix-operators*)
          (format nil "(~A ~A ~A)" (first args) (cdr (assoc op *infix-operators*)) (second args)))
         (t (case op
              (:neg (format nil "-~A" (first args)))
              (:not (format nil "NOT ~A" (first args)))
              (:is-null (format nil "~A IS NULL" (first args)))
              (:is-not-null (format nil "~A IS NOT NULL" (first args)))
              (:cast (format nil "CAST(~A AS ~A)" (first args) (type-name-string (bexpr-type e))))
              (:call (format nil "~A(~{~A~^, ~})" (scalar-function-name (b-op-info e)) args))
              (:subquery (let ((sq (b-op-info e)))
                           (ecase (subquery-kind sq)
                             (:scalar "(subquery)")
                             (:exists "EXISTS(subquery)")
                             (:in (format nil "~A IN (subquery)" (first args))))))
              (t (format nil "~(~A~)(~{~A~^, ~})" op args)))))))
    (b-agg (format nil "~:@(~A~)(~:[~;DISTINCT ~]~:[~{~A~^, ~}~;*~])"
                   (if (eq (b-agg-fn e) :count-star) :count (b-agg-fn e))
                   (b-agg-distinct e) (eq (b-agg-fn e) :count-star)
                   (mapcar #'bexpr-describe (b-agg-args e))))
    (t "?")))
