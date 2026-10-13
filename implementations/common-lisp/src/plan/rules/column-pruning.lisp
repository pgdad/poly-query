;;;; column-pruning.lisp — optimizer rule COLUMN-PRUNING.
;;;;
;;;; Propagates the set of required columns top-down, removes every column
;;;; (scan column, projected expression, union branch column) that no parent
;;;; needs and renumbers column positions, so scans read only referenced
;;;; columns and unused expressions are never evaluated. The plan builder
;;;; applies the same pruning to every new plan (PRUNE-COLUMNS).

(in-package #:polyquery)

(defun column-pruning (plan)
  "Rule: remove the columns of PLAN that no parent needs."
  (prune-columns plan))

(defun prune-columns (node)
  "NODE pruned to the columns its output needs (all of its own columns)."
  (values (prune-node node (loop for i below (lnode-width node) collect i))))

(defun union-columns (required exprs)
  "Sorted union of the positions REQUIRED and the columns used by EXPRS."
  (let ((seen (make-hash-table))
        (acc '()))
    (flet ((add (i)
             (unless (gethash i seen)
               (setf (gethash i seen) t)
               (push i acc))))
      (mapc #'add required)
      (dolist (e exprs)
        (mapc #'add (bexpr-column-indexes e))))
    (sort acc #'<)))

(defun elements-at (list positions)
  "The elements of LIST at POSITIONS (in that order), in linear time."
  (let ((v (coerce list 'simple-vector)))
    (mapcar (lambda (i) (svref v i)) positions)))

(defun prune-node (node required)
  "Prune NODE so that it produces (at least) the REQUIRED output positions.
Returns (values new-node mapping) where MAPPING maps old output positions to
new ones."
  (etypecase node
    (lp-scan
     (values (make-scan (lp-scan-table node) (lp-scan-label node)
                        (mapcar (lambda (i) (svref (lp-scan-column-indexes node) i)) required))
             (make-mapping (lnode-width node) required)))
    (lp-values (values node (vector)))
    (lp-filter
     (multiple-value-bind (child m)
         (prune-node (lnode-child node) (union-columns required (list (lp-filter-predicate node))))
       (values (make-filter child (remap (lp-filter-predicate node) m)) m)))
    (lp-project
     (let ((kept (elements-at (lp-project-exprs node) required)))
       (multiple-value-bind (child m) (prune-node (lnode-child node) (union-columns '() kept))
         (values (make-lp-project :children (list child)
                                  :exprs (mapcar (lambda (e) (remap e m)) kept)
                                  :columns (elements-at (lnode-columns node) required))
                 (make-mapping (lnode-width node) required)))))
    (lp-join
     (destructuring-bind (left right) (lnode-children node)
       (let* ((lw (lnode-width left))
              (cond (lp-join-condition node))
              (need (union-columns required (and cond (list cond)))))
         (multiple-value-bind (new-left ml) (prune-node left (remove-if-not (lambda (i) (< i lw)) need))
           (multiple-value-bind (new-right mr)
               (prune-node right (loop for i in need when (>= i lw) collect (- i lw)))
             (let* ((lw2 (lnode-width new-left))
                    (m (make-array (lnode-width node) :initial-element nil)))
               (dotimes (i lw) (setf (svref m i) (svref ml i)))
               (loop for i from lw below (lnode-width node)
                     for r = (svref mr (- i lw))
                     do (setf (svref m i) (and r (+ r lw2))))
               (values (make-join (lp-join-kind node) new-left new-right (and cond (remap cond m)))
                       m)))))))
    (lp-aggregate
     (let ((keys (lp-aggregate-group-by node))
           (aggs (lp-aggregate-aggregates node)))
       (multiple-value-bind (child m)
           (prune-node (lnode-child node) (union-columns '() (append keys aggs)))
         (values (make-lp-aggregate :children (list child)
                                    :group-by (mapcar (lambda (e) (remap e m)) keys)
                                    :aggregates (mapcar (lambda (e) (remap e m)) aggs)
                                    :columns (lnode-columns node))
                 (make-mapping (lnode-width node) (loop for i below (lnode-width node) collect i))))))
    (lp-distinct
     (let ((child (lnode-child node)))
       (multiple-value-bind (new-child m)
           (prune-node child (loop for i below (lnode-width child) collect i))
         (values (make-distinct new-child) m))))
    (lp-sort
     (multiple-value-bind (child m)
         (prune-node (lnode-child node)
                     (union-columns (append required (mapcar #'first (lp-sort-keys node))) '()))
       (values (make-sort child (loop for (pos . rest) in (lp-sort-keys node)
                                      collect (cons (svref m pos) rest)))
               m)))
    (lp-limit
     (multiple-value-bind (child m) (prune-node (lnode-child node) required)
       (values (make-limit child (lp-limit-limit node) (lp-limit-offset node)) m)))
    (lp-subquery-alias
     (multiple-value-bind (child m) (prune-node (lnode-child node) required)
       (values (make-subquery-alias child (lp-subquery-alias-name node)
                                    :cte (lp-subquery-alias-cte node))
               m)))
    (lp-union-all
     ;; Every branch keeps exactly the REQUIRED columns, in order.
     (values (make-union-all
              (mapcar (lambda (child)
                        (multiple-value-bind (new-child m) (prune-node child required)
                          (if (loop for old in required
                                    for new from 0
                                    always (eql (svref m old) new))
                              new-child
                              (let ((columns (elements-at (lnode-columns child) required)))
                                (make-project new-child
                                              (loop for old in required
                                                    for c in columns
                                                    collect (make-b-column (column-def-type c)
                                                                           (svref m old)
                                                                           (column-def-name c)))
                                              (mapcar #'column-def-name columns))))))
                      (lnode-children node))
              (elements-at (lnode-columns node) required))
             (make-mapping (lnode-width node) required)))))
