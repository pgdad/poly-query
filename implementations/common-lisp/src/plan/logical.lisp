;;;; logical.lisp — the logical plan representation.
;;;;
;;;; A logical plan is a tree of LNODEs describing relational operators
;;;; independently of any execution strategy (no access paths, join
;;;; algorithms or execution modes: those are chosen by physical.lisp).
;;;; Every node produces rows whose layout is described by its COLUMNS (a
;;;; list of COLUMN-DEF); expressions of a node index the row layout of its
;;;; (first) child, a join condition indexes the concatenation of both
;;;; children's layouts.
;;;;
;;;; Node types:
;;;;   Scan            a catalog table (only the listed columns)
;;;;   Values          a single row without columns (SELECT without FROM)
;;;;   Filter          predicate
;;;;   Project         expressions
;;;;   Join            kind (INNER / LEFT / CROSS) and condition
;;;;   Aggregate       group keys and aggregate calls
;;;;   Distinct, Sort (keys), Limit (limit, offset)
;;;;   UnionAll        the rows of the branches one after another
;;;;   SubqueryAlias   a derived table or CTE reference (transparent)
;;;; Subqueries used as expressions (scalar, EXISTS, IN) are not nodes: their
;;;; logical plans hang off the SUBQUERY descriptor of the expression
;;;; (SUBQUERY-LOGICAL-PLAN) and are optimized and planned with the plan.
;;;;
;;;; The plan builder (builder.lisp) creates plans from analysed queries, the
;;;; optimizer (optimizer.lisp, rules/) rewrites them.

(in-package #:polyquery)

(defstruct (lnode (:constructor nil))
  (children '())
  (columns '()))

(defstruct (lp-scan (:include lnode))
  table
  label                                  ; range variable name
  (column-indexes #() :type simple-vector))

(defstruct (lp-values (:include lnode))
  "Produces a single row without columns (SELECT without FROM).")

(defstruct (lp-filter (:include lnode))
  predicate)

(defstruct (lp-project (:include lnode))
  exprs)

(defstruct (lp-join (:include lnode))
  kind                                   ; :INNER :LEFT :CROSS
  condition)                             ; BEXPR over left ++ right, or NIL

(defstruct (lp-aggregate (:include lnode))
  group-by aggregates)                   ; output: keys ++ aggregate values

(defstruct (lp-distinct (:include lnode)))

(defstruct (lp-sort (:include lnode))
  keys)                                  ; list of (position type descending nulls-first)

(defstruct (lp-limit (:include lnode))
  limit offset)                          ; constant BEXPRs or NIL

(defstruct (lp-union-all (:include lnode))
  "Concatenation of the rows of its children (the UNION ALL branches).")

(defstruct (lp-subquery-alias (:include lnode))
  "The rows of a derived table or CTE reference (its single child) under the
range variable NAME; it does not change the rows."
  name
  (cte nil))                             ; true for a CTE reference

(defun lnode-child (node) (first (lnode-children node)))
(defun lnode-width (node) (length (lnode-columns node)))

(defun describe-columns (exprs)
  (mapcar (lambda (e) (make-column-def (bexpr-describe e) (bexpr-type e))) exprs))

;;; ------------------------------------------------------------------
;;; Constructors computing the output layout

(defun make-scan (table label column-indexes)
  (make-lp-scan :table table :label label
                :column-indexes (coerce column-indexes 'simple-vector)
                :columns (map 'list (lambda (i) (svref (table-columns table) i)) column-indexes)))

(defun make-filter (child predicate)
  (if predicate
      (make-lp-filter :children (list child) :predicate predicate :columns (lnode-columns child))
      child))

(defun make-project (child exprs &optional names)
  (make-lp-project :children (list child) :exprs exprs
                   :columns (if names
                                (mapcar (lambda (n e) (make-column-def n (bexpr-type e))) names exprs)
                                (describe-columns exprs))))

(defun make-join (kind left right condition)
  (make-lp-join :kind kind :children (list left right) :condition condition
                :columns (append (lnode-columns left) (lnode-columns right))))

(defun make-aggregate (child group-by aggregates)
  (make-lp-aggregate :children (list child) :group-by group-by :aggregates aggregates
                     :columns (describe-columns (append group-by aggregates))))

(defun make-distinct (child)
  (make-lp-distinct :children (list child) :columns (lnode-columns child)))

(defun make-sort (child keys)
  (make-lp-sort :children (list child) :keys keys :columns (lnode-columns child)))

(defun make-union-all (children columns)
  (make-lp-union-all :children children :columns columns))

(defun make-limit (child limit offset)
  (make-lp-limit :children (list child) :limit limit :offset offset
                 :columns (lnode-columns child)))

(defun make-subquery-alias (child name &key cte)
  (make-lp-subquery-alias :children (list child) :name name :cte cte
                          :columns (lnode-columns child)))

;;; ------------------------------------------------------------------
;;; Generic traversal

(defun rebuild-with-children (node children)
  "NODE with its children replaced by CHILDREN (NODE itself if unchanged)."
  (if (every #'eq children (lnode-children node))
      node
      (let ((copy (copy-structure node)))
        (setf (lnode-children copy) children)
        copy)))

(defun map-plan-expressions (fn node)
  "Copy of the plan NODE in which every expression of every Filter, Project,
Join and Aggregate node is replaced by (FN expression)."
  (let ((copy (copy-structure node)))
    (setf (lnode-children copy) (mapcar (lambda (c) (map-plan-expressions fn c))
                                        (lnode-children node)))
    (typecase copy
      (lp-filter (setf (lp-filter-predicate copy) (funcall fn (lp-filter-predicate copy))))
      (lp-project (setf (lp-project-exprs copy) (mapcar fn (lp-project-exprs copy))))
      (lp-join (when (lp-join-condition copy)
                 (setf (lp-join-condition copy) (funcall fn (lp-join-condition copy)))))
      (lp-aggregate (setf (lp-aggregate-group-by copy) (mapcar fn (lp-aggregate-group-by copy))
                          (lp-aggregate-aggregates copy) (mapcar fn (lp-aggregate-aggregates copy)))))
    copy))

(defun lnode-expressions (node)
  "The expressions evaluated by NODE itself (not those of its children)."
  (typecase node
    (lp-filter (list (lp-filter-predicate node)))
    (lp-project (lp-project-exprs node))
    (lp-join (and (lp-join-condition node) (list (lp-join-condition node))))
    (lp-aggregate (append (lp-aggregate-group-by node) (lp-aggregate-aggregates node)))
    (lp-limit (remove nil (list (lp-limit-limit node) (lp-limit-offset node))))
    (t '())))

(defun map-plan-subqueries (fn node)
  "Call FN on the SUBQUERY descriptor of every expression subquery used by
the plan NODE (not descending into the subqueries' own plans), in plan
order; a descriptor used several times is passed once."
  (let ((seen '()))
    (labels ((walk (n)
               (dolist (e (lnode-expressions n))
                 (bexpr-walk (lambda (x)
                               (when (subquery-op-p x)
                                 (let ((sq (b-op-info x)))
                                   (unless (member sq seen)
                                     (push sq seen)
                                     (funcall fn sq)))))
                             e))
               (mapc #'walk (lnode-children n))))
      (walk node))))

;;; ------------------------------------------------------------------
;;; Column positions

(defun columns-within-p (e low high)
  "True if every column E references lies in [LOW, HIGH)."
  (every (lambda (i) (and (<= low i) (< i high))) (bexpr-column-indexes e)))

(defun make-mapping (width kept)
  "Vector mapping old positions (of WIDTH) to new ones; KEPT are the old
positions that survive, in their new order."
  (let ((m (make-array width :initial-element nil)))
    (loop for old in kept for new from 0 do (setf (svref m old) new))
    m))

(defun remap (e mapping)
  "Copy of E with its column positions translated through the MAPPING vector."
  (bexpr-remap-columns e (lambda (i)
                           (or (svref mapping i)
                               (error "internal: pruned column ~D still referenced" i)))))

;;; ------------------------------------------------------------------
;;; Printing (debugging and unit tests; not part of the protocol)

(defun lnode-label (node)
  "One-line description of NODE without its children."
  (flet ((exprs (list) (format nil "~{~A~^, ~}" (mapcar #'bexpr-describe list)))
         (names (node) (format nil "~{~A~^, ~}" (mapcar #'column-def-name (lnode-columns node)))))
    (etypecase node
      (lp-scan (format nil "Scan ~A AS ~A [~A]" (table-name (lp-scan-table node))
                       (lp-scan-label node) (names node)))
      (lp-values "Values")
      (lp-filter (format nil "Filter ~A" (bexpr-describe (lp-filter-predicate node))))
      (lp-project (format nil "Project [~A]" (exprs (lp-project-exprs node))))
      (lp-join (format nil "Join ~A~@[ ON ~A~]" (lp-join-kind node)
                       (and (lp-join-condition node) (bexpr-describe (lp-join-condition node)))))
      (lp-aggregate (format nil "Aggregate keys [~A] aggregates [~A]"
                            (exprs (lp-aggregate-group-by node))
                            (exprs (lp-aggregate-aggregates node))))
      (lp-distinct "Distinct")
      (lp-sort (format nil "Sort [~{~A~^, ~}]"
                       (loop for (pos nil desc nulls-first) in (lp-sort-keys node)
                             collect (format nil "~A ~:[ASC~;DESC~] NULLS ~:[LAST~;FIRST~]"
                                             (column-def-name (nth pos (lnode-columns node)))
                                             desc nulls-first))))
      (lp-limit (format nil "Limit ~A offset ~A"
                        (if (lp-limit-limit node) (bexpr-describe (lp-limit-limit node)) "-")
                        (if (lp-limit-offset node) (bexpr-describe (lp-limit-offset node)) "-")))
      (lp-union-all (format nil "UnionAll [~A]" (names node)))
      (lp-subquery-alias (format nil "SubqueryAlias ~A~:[~; (CTE)~] [~A]"
                                 (lp-subquery-alias-name node) (lp-subquery-alias-cte node)
                                 (names node))))))

(defun format-logical-plan (node &optional (stream nil))
  "Render the logical plan NODE as an indented tree, one node per line;
the plans of expression subqueries follow the node that uses them. Returns a
string when STREAM is NIL."
  (labels ((emit (n depth out)
             (format out "~vA~A~%" (* 2 depth) "" (lnode-label n))
             (dolist (e (lnode-expressions n))
               (bexpr-walk (lambda (x)
                             (when (subquery-op-p x)
                               (let ((sq (b-op-info x)))
                                 (format out "~vASubquery ~(~A~)~%" (* 2 (1+ depth)) ""
                                         (subquery-kind sq))
                                 (when (subquery-logical-plan sq)
                                   (emit (subquery-logical-plan sq) (+ depth 2) out)))))
                           e))
             (dolist (c (lnode-children n))
               (emit c (1+ depth) out))))
    (if stream
        (emit node 0 stream)
        (with-output-to-string (out) (emit node 0 out)))))
