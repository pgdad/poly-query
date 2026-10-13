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
  type
  ;; Lazily computed summaries of the subtree (see BEXPR-PROPERTIES and
  ;; BEXPR-COLUMN-INDEXES). Nodes are never mutated after construction, so
  ;; the caches stay valid; they keep the per-node checks of the planner and
  ;; the compilers linear in the size of an expression (CR-6).
  (properties-cache nil)
  (column-cache :unknown)
  (hash-cache nil)
  (size-cache nil))

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
  logical-plan                          ; logical plan, filled in by the plan builder
  plan)                                 ; physical plan, filled in by the physical planner

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

(defconstant +prop-column+ 1)
(defconstant +prop-aggregate+ 2)
(defconstant +prop-param+ 4)
(defconstant +prop-subquery+ 8)
(defconstant +prop-may-fail+ 16)
(defconstant +prop-test-only+ 32)

(defun bexpr-properties (e)
  "Bit mask of the +PROP-...+ flags that hold for some node of E (memoized
per node)."
  (or (bexpr-properties-cache e)
      (setf (bexpr-properties-cache e)
            (let ((own (typecase e
                         (b-column +prop-column+)
                         (b-param +prop-param+)
                         (b-agg +prop-aggregate+)
                         (b-op (logior (if (subquery-op-p e) +prop-subquery+ 0)
                                       (if (node-may-fail-p e) +prop-may-fail+ 0)
                                       (if (and (eq (b-op-op e) :call)
                                                (scalar-function-test-only (b-op-info e)))
                                           +prop-test-only+ 0)))
                         (t 0))))
              (dolist (c (bexpr-children e) own)
                (setf own (logior own (bexpr-properties c))))))))

(declaim (inline bexpr-has-p))
(defun bexpr-has-p (e flags)
  "True if some node of E has one of the property FLAGS."
  (logtest (bexpr-properties e) flags))

(defun bexpr-contains-aggregate-p (e)
  (bexpr-has-p e +prop-aggregate+))

(defun bexpr-constant-p (e)
  "True if E depends on nothing but literals (no columns, parameters,
aggregates or subqueries)."
  (not (bexpr-has-p e (logior +prop-column+ +prop-aggregate+ +prop-param+ +prop-subquery+))))

(defun bexpr-list-equal (as bs)
  (loop (cond ((and (null as) (null bs)) (return t))
              ((or (null as) (null bs) (not (bexpr-equal (pop as) (pop bs)))) (return nil)))))

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
              (bexpr-list-equal (b-op-args a) (b-op-args b))))
        ((and (b-agg-p a) (b-agg-p b))
         (and (eq (b-agg-fn a) (b-agg-fn b))
              (eq (b-agg-distinct a) (b-agg-distinct b))
              (bexpr-list-equal (b-agg-args a) (b-agg-args b))))
        (t nil)))

(defun bexpr-node-count (e)
  "Number of nodes of E (memoized per node)."
  (or (bexpr-size-cache e)
      (setf (bexpr-size-cache e)
            (let ((n 1))
              (dolist (c (bexpr-children e) n)
                (incf n (bexpr-node-count c)))))))

(defun interrupt-checkpoint-p (e granularity)
  "True if compiled code evaluating E should check the query deadline before
evaluating it: E's subtree size crosses a multiple of GRANULARITY that none
of its children's does. Evaluating any subtree then performs at most about
GRANULARITY nodes of work between two checks, and small expressions get no
checks at all (CR-6: long expressions keep the timeout prompt)."
  (let ((level (floor (bexpr-node-count e) granularity)))
    (and (plusp level)
         (every (lambda (c) (< (floor (bexpr-node-count c) granularity) level))
                (bexpr-children e)))))

(defun bexpr-hash (e)
  "Structural hash of E, consistent with BEXPR-EQUAL (memoized per node)."
  (or (bexpr-hash-cache e)
      (setf (bexpr-hash-cache e)
            (flet ((mix (h x) (logand (+ (* h 31) x) most-positive-fixnum)))
              (typecase e
                (b-literal (mix (sxhash (type-kind (bexpr-type e))) (sxhash (b-literal-value e))))
                (b-column (mix 1 (b-column-index e)))
                (b-param (mix 2 (b-param-index e)))
                (b-op (let ((h (sxhash (b-op-op e))))
                        (dolist (c (b-op-args e) h)
                          (setf h (mix h (bexpr-hash c))))))
                (b-agg (let ((h (mix (sxhash (b-agg-fn e)) (if (b-agg-distinct e) 1 0))))
                         (dolist (c (b-agg-args e) h)
                           (setf h (mix h (bexpr-hash c))))))
                (t 0))))))

(defstruct (bexpr-index (:constructor %make-bexpr-index))
  "A list of distinct (by BEXPR-EQUAL) expressions with hashed lookup of
their positions, for matching expressions against long lists in linear time."
  (table (make-hash-table) :type hash-table) ; hash -> list of (expr . position)
  (items '())                                ; expressions, most recent first
  (count 0 :type fixnum))

(defun bexpr-index-position (index e)
  "Position of the expression equal to E in INDEX, or NIL."
  (cdr (assoc e (gethash (bexpr-hash e) (bexpr-index-table index)) :test #'bexpr-equal)))

(defun bexpr-index-add (index e)
  "Position of E in INDEX, adding it at the end if no equal expression is
present yet."
  (or (bexpr-index-position index e)
      (let ((k (bexpr-index-count index)))
        (push (cons e k) (gethash (bexpr-hash e) (bexpr-index-table index)))
        (push e (bexpr-index-items index))
        (setf (bexpr-index-count index) (1+ k))
        k)))

(defun make-bexpr-index (&optional exprs)
  "An index of the expressions EXPRS: duplicates map to their first position
(positions still count every element of EXPRS)."
  (let ((index (%make-bexpr-index)))
    (loop for e in exprs
          for k from 0
          do (unless (bexpr-index-position index e)
               (push (cons e k) (gethash (bexpr-hash e) (bexpr-index-table index))))
             (push e (bexpr-index-items index))
             (setf (bexpr-index-count index) (1+ k)))
    index))

(defun bexpr-index-list (index)
  "The expressions of INDEX in order."
  (reverse (bexpr-index-items index)))

(defun bexpr-rewrite (fn e)
  "Rebuild E top-down: FN returns a replacement node or NIL to descend."
  (check-interrupts)                    ; the query timeout covers planning (CR-6)
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
  "List of distinct column indexes referenced by E (memoized per node; the
list is shared and must not be modified)."
  (let ((cached (bexpr-column-cache e)))
    (if (listp cached)
        cached
        (setf (bexpr-column-cache e)
              (if (b-column-p e)
                  (list (b-column-index e))
                  (let ((acc '()))
                    (dolist (c (bexpr-children e) acc)
                      (let ((cols (bexpr-column-indexes c)))
                        (cond ((null acc) (setf acc cols))
                              ((subsetp cols acc))
                              ((subsetp acc cols) (setf acc cols))
                              (t (setf acc (union cols acc))))))))))))

(defun split-conjuncts (e)
  "Flatten a tree of ANDs into the list of its conjuncts (in order)."
  (let ((acc '()))
    (labels ((walk (x)
               (if (and (b-op-p x) (eq (b-op-op x) :and))
                   (dolist (a (b-op-args x)) (walk a))
                   (push x acc))))
      (walk e))
    (nreverse acc)))

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

(defun node-may-fail-p (e)
  (and (b-op-p e)
       (case (b-op-op e)
         ((:+ :- :* :/ :% :neg :call :subquery) t)
         (:cast (not (safe-cast-p (bexpr-type (first (b-op-args e))) (bexpr-type e))))
         (t nil))))

(defun may-fail-p (e)
  "True if evaluating E can signal an error for some row."
  (bexpr-has-p e +prop-may-fail+))

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
  relation query
  (cte nil))               ; true for a CTE reference

(defstruct (bf-join (:include bf-node))
  kind left right condition)   ; kind :INNER :LEFT :CROSS; condition over the FROM row

(defstruct (bf-union (:include bf-node))
  "The rows of all BRANCHES (BOUND-QUERYs) of a UNION ALL, converted to the
COLUMNS (COLUMN-DEFs carrying the common types)."
  branches columns)

;;; ------------------------------------------------------------------
;;; Rendering (EXPLAIN and error messages)

(defparameter *infix-operators*
  '((:+ . "+") (:- . "-") (:* . "*") (:/ . "/") (:% . "%") (:concat . "||")
    (:= . "=") (:<> . "<>") (:< . "<") (:<= . "<=") (:> . ">") (:>= . ">=")
    (:and . "AND") (:or . "OR")))

(defun bexpr-describe (e)
  "Compact SQL-like rendering of a bound expression."
  (with-output-to-string (out)
    (write-bexpr-description e out)))

(defun write-bexpr-description (e out)
  "Write the BEXPR-DESCRIBE rendering of E to the stream OUT (linear in the
size of E, also for long operator chains)."
  (labels ((args (list)
             (loop for (a . more) on list
                   do (write-bexpr-description a out)
                      (when more (write-string ", " out)))))
    (typecase e
      (b-literal (write-string
                  (cond ((null-value-p (b-literal-value e)) "NULL")
                        ((member (type-kind (bexpr-type e)) '(:string :date :timestamp))
                         (format nil "'~A'" (value-to-text (b-literal-value e) (bexpr-type e))))
                        (t (value-to-text (b-literal-value e) (bexpr-type e))))
                  out))
      (b-column (if (b-column-name e)
                    (princ (b-column-name e) out)
                    (format out "#~D" (b-column-index e))))
      (b-param (format out "outer.~A" (or (b-param-name e) (b-param-index e))))
      (b-op
       (let* ((op (b-op-op e))
              (args (b-op-args e))
              (infix (cdr (assoc op *infix-operators*))))
         (cond
           (infix
            (write-char #\( out)
            (write-bexpr-description (first args) out)
            (format out " ~A " infix)
            (write-bexpr-description (second args) out)
            (write-char #\) out))
           (t (case op
                (:neg (write-char #\- out) (write-bexpr-description (first args) out))
                (:not (write-string "NOT " out) (write-bexpr-description (first args) out))
                ((:is-null :is-not-null)
                 (write-bexpr-description (first args) out)
                 (write-string (if (eq op :is-null) " IS NULL" " IS NOT NULL") out))
                (:cast (write-string "CAST(" out)
                 (write-bexpr-description (first args) out)
                 (format out " AS ~A)" (type-name-string (bexpr-type e))))
                (:call (format out "~A(" (scalar-function-name (b-op-info e)))
                 (args args)
                 (write-char #\) out))
                (:subquery (let ((sq (b-op-info e)))
                             (ecase (subquery-kind sq)
                               (:scalar (write-string "(subquery)" out))
                               (:exists (write-string "EXISTS(subquery)" out))
                               (:in (write-bexpr-description (first args) out)
                                (write-string " IN (subquery)" out)))))
                (t (format out "~(~A~)(" op)
                 (args args)
                 (write-char #\) out)))))))
      (b-agg (format out "~:@(~A~)(~:[~;DISTINCT ~]"
                     (if (eq (b-agg-fn e) :count-star) :count (b-agg-fn e))
                     (b-agg-distinct e))
             (if (eq (b-agg-fn e) :count-star)
                 (write-char #\* out)
                 (args (b-agg-args e)))
             (write-char #\) out))
      (t (write-char #\? out)))))
