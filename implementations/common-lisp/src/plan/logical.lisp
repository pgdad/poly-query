;;;; logical.lisp — logical query plans built from analysed queries.
;;;;
;;;; A logical plan is a tree of LNODEs. Every node produces rows whose layout
;;;; is described by its COLUMNS (a list of COLUMN-DEF); expressions of a node
;;;; index the row layout of its (first) child, a join condition indexes the
;;;; concatenation of both children's layouts.
;;;;
;;;; Shape for a SELECT:
;;;;   FROM tree (Scan / Join / derived plans) or Values
;;;;     -> [Filter WHERE] -> [Aggregate -> [Filter HAVING]]
;;;;     -> Project(outputs + hidden sort keys) -> [Distinct] -> [Sort]
;;;;     -> [Limit] -> [Project(strip hidden keys)]

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

(defun make-limit (child limit offset)
  (make-lp-limit :children (list child) :limit limit :offset offset
                 :columns (lnode-columns child)))

;;; ------------------------------------------------------------------
;;; Plan construction

(defun plan-from (bf)
  "Logical plan producing the FROM row of the BF-* subtree."
  (etypecase bf
    (bf-table
     (let ((table (bf-table-table bf)))
       (make-scan table (relation-name (bf-table-relation bf))
                  (loop for i below (table-column-count table) collect i))))
    (bf-derived (plan-query (bf-derived-query bf)))
    (bf-join
     (make-join (bf-join-kind bf)
                (plan-from (bf-join-left bf))
                (plan-from (bf-join-right bf))
                (and (bf-join-condition bf)
                     (bexpr-shift-columns (bf-join-condition bf) (- (bf-node-offset bf))))))))

(defun plan-query (bq)
  "Build the (unoptimized) logical plan of the BOUND-QUERY BQ."
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
    (setf node (make-project node (append outputs hidden)
                             (append names (mapcar #'bexpr-describe hidden))))
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
