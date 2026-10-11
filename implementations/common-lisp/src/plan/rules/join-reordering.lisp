;;;; join-reordering.lisp — optimizer rule JOIN-REORDERING.
;;;;
;;;; Rewrites chains of three or more inner joins whose written order
;;;; contains a cross product into a left-deep order that starts with the
;;;; smallest input (statistics-based estimates, estimates.lisp) and always
;;;; adds a connected input (avoiding cross products), smallest first; a
;;;; Project restores the original column order. Other join orders are kept:
;;;; without join selectivity estimates the written order is the better guess.

(in-package #:polyquery)

(defun join-reordering (plan)
  "Rule: reorder the inner-join chains of PLAN that contain cross products."
  (reorder-joins plan))

(defun inner-join-node-p (node)
  (and (lp-join-p node) (member (lp-join-kind node) '(:inner :cross))))

(defun collect-inner-joins (node offset)
  "Leaves of the inner-join tree NODE as (plan offset) lists and all join
conjuncts, with column positions relative to the tree's row (NODE at OFFSET)."
  (if (inner-join-node-p node)
      (destructuring-bind (left right) (lnode-children node)
        (multiple-value-bind (left-leaves left-conjuncts) (collect-inner-joins left offset)
          (multiple-value-bind (right-leaves right-conjuncts)
              (collect-inner-joins right (+ offset (lnode-width left)))
            (values (append left-leaves right-leaves)
                    (append left-conjuncts right-conjuncts
                            (mapcar (lambda (c) (bexpr-shift-columns c offset))
                                    (and (lp-join-condition node)
                                         (split-conjuncts (lp-join-condition node)))))))))
      (values (list (list (reorder-joins node) offset)) '())))

(defun cross-product-p (node)
  "True if the inner-join tree NODE contains a join without condition."
  (and (inner-join-node-p node)
       (or (null (lp-join-condition node))
           (some #'cross-product-p (lnode-children node)))))

(defun reorder-joins (node)
  "Reorder every chain of at least three inner joins in NODE whose written
order contains a cross product (other orders are kept: without join
selectivity estimates the written order is the better guess)."
  (if (and (inner-join-node-p node) (cross-product-p node))
      (multiple-value-bind (leaves conjuncts) (collect-inner-joins node 0)
        (if (< (length leaves) 3)
            (rebuild-with-children node (mapcar #'reorder-joins (lnode-children node)))
            (greedy-join-order node leaves conjuncts)))
      (rebuild-with-children node (mapcar #'reorder-joins (lnode-children node)))))

(defun greedy-join-order (node leaves conjuncts)
  "Left-deep join of LEAVES ((plan offset) lists) applying CONJUNCTS (over
NODE's row) as early as possible; a Project restores NODE's column order."
  (let* ((width (lnode-width node))
         (mapping (make-array width :initial-element nil))
         (remaining (mapcar (lambda (leaf)
                              (destructuring-bind (plan offset) leaf
                                (list plan offset (lnode-width plan) (estimate-rows plan))))
                            leaves))
         (pending conjuncts)
         (plan nil)
         (placed-width 0))
    (labels ((leaf-columns (leaf)
               (destructuring-bind (plan offset w est) leaf
                 (declare (ignore plan est))
                 (loop for i from offset below (+ offset w) collect i)))
             (placed-p (i) (svref mapping i))
             (applicable (c leaf)
               ;; C only reads placed columns and LEAF's.
               (let ((cols (leaf-columns leaf)))
                 (every (lambda (i) (or (placed-p i) (member i cols))) (bexpr-column-indexes c))))
             (connects-p (leaf)
               (let ((cols (leaf-columns leaf)))
                 (some (lambda (c)
                         (let ((used (bexpr-column-indexes c)))
                           (and (applicable c leaf)
                                (some (lambda (i) (member i cols)) used)
                                (some #'placed-p used))))
                       pending)))
             (smallest (candidates)
               (let ((best nil))
                 (dolist (leaf candidates best)
                   (when (or (null best) (< (fourth leaf) (fourth best)))
                     (setf best leaf)))))
             (place (leaf)
               (destructuring-bind (leaf-plan offset w est) leaf
                 (declare (ignore est))
                 (dotimes (k w) (setf (svref mapping (+ offset k)) (+ placed-width k)))
                 (incf placed-width w)
                 (let ((conds (remove-if-not (lambda (c) (applicable c leaf)) pending)))
                   (setf pending (set-difference pending conds))
                   (setf conds (sort-by-original-order conds conjuncts))
                   (let ((condition (and conds (conjoin (mapcar (lambda (c) (remap c mapping)) conds)))))
                     (setf plan (if plan
                                    (make-join (if conds :inner :cross) plan leaf-plan condition)
                                    ;; Conjuncts over the first input alone (constants).
                                    (make-filter leaf-plan condition)))))
                 (setf remaining (remove leaf remaining)))))
      (place (smallest remaining))
      (loop while remaining
            do (place (smallest (or (remove-if-not #'connects-p remaining) remaining))))
      (when pending
        (setf plan (make-filter plan (conjoin (mapcar (lambda (c) (remap c mapping)) pending)))))
      (make-project plan
                    (loop for i below width
                          for c in (lnode-columns node)
                          collect (make-b-column (column-def-type c) (svref mapping i)
                                                 (column-def-name c)))
                    (mapcar #'column-def-name (lnode-columns node))))))

(defun sort-by-original-order (subset all)
  (remove-if-not (lambda (c) (member c subset)) all))

