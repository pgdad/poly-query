;;;; optimizer.lisp — logical rewrites: predicate pushdown and column pruning.
;;;;
;;;; Both passes are semantics preserving rewrites of LNODE trees:
;;;;  * PUSH-DOWN-PREDICATES splits filter and join conditions into conjuncts
;;;;    and moves each one as close to the scans as possible: below joins
;;;;    (never into the NULL-supplying side of a LEFT JOIN from above) and
;;;;    into the conditions of inner joins, so comma joins become equi-joins.
;;;;  * PRUNE-COLUMNS removes every column a parent does not need, so scans
;;;;    read only referenced columns.

(in-package #:polyquery)

(defun optimize-logical-plan (node)
  "Apply the logical rewrites; with `optimize: false` only column pruning,
which the engine's evaluation guarantees rely on (see README)."
  (if (exec-options-optimize *exec-options*)
      (prune-columns (push-down-predicates node))
      (prune-columns node)))

;;; ------------------------------------------------------------------
;;; Predicate pushdown

(defun push-down-predicates (node)
  (typecase node
    (lp-filter (push-conjuncts (lnode-child node) (split-conjuncts (lp-filter-predicate node))))
    (lp-join (push-conjuncts node '()))
    (t (rebuild-with-children node (mapcar #'push-down-predicates (lnode-children node))))))

(defun rebuild-with-children (node children)
  (if (every #'eq children (lnode-children node))
      node
      (let ((copy (copy-structure node)))
        (setf (lnode-children copy) children)
        copy)))

(defun columns-within-p (e low high)
  "True if every column E references lies in [LOW, HIGH)."
  (every (lambda (i) (and (<= low i) (< i high))) (bexpr-column-indexes e)))

(defun push-conjuncts (node conjuncts)
  "Plan NODE with the CONJUNCTS (over NODE's output layout) applied on top,
pushing each conjunct as far down as is valid."
  (typecase node
    (lp-filter
     (push-conjuncts (lnode-child node)
                     (append conjuncts (split-conjuncts (lp-filter-predicate node)))))
    (lp-join (push-into-join node conjuncts))
    (t (make-filter (push-down-predicates node) (conjoin conjuncts)))))

(defun push-into-join (node conjuncts)
  (destructuring-bind (left right) (lnode-children node)
    (let* ((kind (lp-join-kind node))
           (lw (lnode-width left))
           (width (lnode-width node))
           (outer-join (eq kind :left))
           (to-left '()) (to-right '()) (to-join '()) (above '()))
      ;; Conjuncts from above the join (WHERE or enclosing filters).
      (dolist (c conjuncts)
        (cond ((columns-within-p c 0 lw) (push c to-left))
              (outer-join (push c above))
              ((columns-within-p c lw width) (push c to-right))
              (t (push c to-join))))
      ;; Conjuncts of the join's own condition.
      (dolist (c (and (lp-join-condition node) (split-conjuncts (lp-join-condition node))))
        (cond ((and (not outer-join) (columns-within-p c 0 lw)) (push c to-left))
              ((columns-within-p c lw width) (push c to-right))
              (t (push c to-join))))
      (let ((join (make-join (if (and (eq kind :cross) to-join) :inner kind)
                             (push-conjuncts left (nreverse to-left))
                             (push-conjuncts right (mapcar (lambda (c) (bexpr-shift-columns c (- lw)))
                                                           (nreverse to-right)))
                             (conjoin (nreverse to-join)))))
        (make-filter join (conjoin (nreverse above)))))))

;;; ------------------------------------------------------------------
;;; Column pruning

(defun prune-columns (node)
  (values (prune-node node (loop for i below (lnode-width node) collect i))))

(defun union-columns (required exprs)
  "Sorted union of the positions REQUIRED and the columns used by EXPRS."
  (sort (remove-duplicates (append required (mapcan #'bexpr-column-indexes exprs))) #'<))

(defun make-mapping (width kept)
  "Vector mapping old positions (of WIDTH) to new ones; KEPT are the old
positions that survive, in their new order."
  (let ((m (make-array width :initial-element nil)))
    (loop for old in kept for new from 0 do (setf (svref m old) new))
    m))

(defun remap (e mapping)
  (bexpr-remap-columns e (lambda (i)
                           (or (svref mapping i)
                               (error "internal: pruned column ~D still referenced" i)))))

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
     (let ((kept (mapcar (lambda (i) (nth i (lp-project-exprs node))) required)))
       (multiple-value-bind (child m) (prune-node (lnode-child node) (union-columns '() kept))
         (values (make-lp-project :children (list child)
                                  :exprs (mapcar (lambda (e) (remap e m)) kept)
                                  :columns (mapcar (lambda (i) (nth i (lnode-columns node))) required))
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
                     (sort (remove-duplicates (append required (mapcar #'first (lp-sort-keys node))))
                           #'<))
       (values (make-sort child (loop for (pos . rest) in (lp-sort-keys node)
                                      collect (cons (svref m pos) rest)))
               m)))
    (lp-limit
     (multiple-value-bind (child m) (prune-node (lnode-child node) required)
       (values (make-limit child (lp-limit-limit node) (lp-limit-offset node)) m)))))
