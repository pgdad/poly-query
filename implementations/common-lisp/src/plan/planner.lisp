;;;; planner.lisp — logical plan construction from a BOUND-SELECT.
;;;;
;;;; Plan shape for a SELECT:
;;;;   Scan/Values -> [Filter] -> [Aggregate] -> Project(outputs + hidden sort keys)
;;;;     -> [Sort] -> [Limit] -> [Project(strip hidden keys)]
;;;; The scan reads only the referenced columns (column pruning); input-side
;;;; expressions are remapped to the scan's output positions.

(in-package #:polyquery)

(defstruct (plan-node (:constructor nil))
  (children '()))

(defstruct (plan-scan (:include plan-node))
  table
  (columns #() :type simple-vector))     ; table column indexes to read

(defstruct (plan-values (:include plan-node))
  "Produces a single empty row (SELECT without FROM).")

(defstruct (plan-filter (:include plan-node))
  predicate)

(defstruct (plan-aggregate (:include plan-node))
  group-by aggregates)

(defstruct (plan-project (:include plan-node))
  exprs)

(defstruct (plan-sort (:include plan-node))
  keys)                                  ; list of (position type descending nulls-first)

(defstruct (plan-limit (:include plan-node))
  limit offset)

(defstruct planned-query
  root
  columns)                               ; list of COLUMN-DEF describing the result

(defun plan-child (node) (first (plan-node-children node)))

(defun plan-select (bound)
  "Build the logical plan for BOUND, a BOUND-SELECT."
  (let* ((table (bound-select-table bound))
         (aggregated (bound-select-aggregated-p bound))
         (outputs (bound-select-outputs bound))
         (hidden (bound-select-hidden bound))
         (input-exprs (append (when (bound-select-where bound) (list (bound-select-where bound)))
                              (bound-select-group-by bound)
                              (bound-select-aggregates bound)
                              (unless aggregated (append (mapcar #'cdr outputs) hidden))))
         (used (sort (remove-duplicates (mapcan #'bexpr-column-indexes input-exprs)) #'<))
         (mapping (let ((h (make-hash-table)))
                    (loop for c in used for i from 0 do (setf (gethash c h) i))
                    h))
         (remap (lambda (e) (bexpr-remap-columns e (lambda (i) (gethash i mapping)))))
         (node (if table
                   (make-plan-scan :table table :columns (coerce used 'simple-vector))
                   (make-plan-values))))
    (when (bound-select-where bound)
      (setf node (make-plan-filter :children (list node)
                                   :predicate (funcall remap (bound-select-where bound)))))
    (when aggregated
      (setf node (make-plan-aggregate
                  :children (list node)
                  :group-by (mapcar remap (bound-select-group-by bound))
                  :aggregates (mapcar remap (bound-select-aggregates bound)))))
    (let ((project-exprs (append (mapcar #'cdr outputs) hidden)))
      (setf node (make-plan-project
                  :children (list node)
                  :exprs (if aggregated project-exprs (mapcar remap project-exprs)))))
    (when (bound-select-order bound)
      (let ((all (append (mapcar #'cdr outputs) hidden)))
        (setf node (make-plan-sort
                    :children (list node)
                    :keys (loop for (pos desc nulls-first) in (bound-select-order bound)
                                collect (list pos (bexpr-type (nth pos all)) desc nulls-first))))))
    (when (or (bound-select-limit bound) (bound-select-offset bound))
      (setf node (make-plan-limit :children (list node)
                                  :limit (bound-select-limit bound)
                                  :offset (or (bound-select-offset bound) 0))))
    (when hidden
      (setf node (make-plan-project
                  :children (list node)
                  :exprs (loop for (nil . e) in outputs
                               for i from 0
                               collect (make-b-column (bexpr-type e) i nil)))))
    (make-planned-query
     :root node
     :columns (loop for (name . e) in outputs
                    collect (make-column-def name (output-type (bexpr-type e)))))))
