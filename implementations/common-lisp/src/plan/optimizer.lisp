;;;; optimizer.lisp — logical rewrites.
;;;;
;;;; All passes are semantics preserving rewrites of LNODE trees:
;;;;  * SIMPLIFY-PLAN folds constant subexpressions into literals (when their
;;;;    evaluation succeeds; an expression that fails stays, so the error is
;;;;    raised only if a row evaluates it) and simplifies predicates
;;;;    (TRUE/FALSE operands of AND/OR, double negation, negated comparisons,
;;;;    duplicate conjuncts); a filter that is always TRUE disappears.
;;;;  * PUSH-DOWN-PREDICATES splits filter and join conditions into conjuncts
;;;;    and moves each one as close to the scans as possible: below joins
;;;;    (never into the NULL-supplying side of a LEFT JOIN from above) and
;;;;    into the conditions of inner joins, so comma joins become equi-joins.
;;;;  * REORDER-JOINS rewrites chains of three or more inner joins whose
;;;;    written order contains a cross product into a left-deep order that
;;;;    starts with the smallest input and always adds a connected input
;;;;    (avoiding cross products), smallest first.
;;;;  * PRUNE-COLUMNS removes every column a parent does not need, so scans
;;;;    read only referenced columns.
;;;; With `optimize: false` only column pruning runs (Phase 3 requires the
;;;; pruned scans, and it guarantees that unused expressions are never
;;;; evaluated).

(in-package #:polyquery)

(defun optimize-logical-plan (node)
  (if (exec-options-optimize *exec-options*)
      (prune-columns (reorder-joins (push-down-predicates (simplify-plan node))))
      (prune-columns node)))

;;; ------------------------------------------------------------------
;;; Constant folding and predicate simplification

(defun foldable-p (e)
  "True if E is a constant expression worth (and safe) evaluating now."
  (and (b-op-p e)
       (bexpr-constant-p e)
       (not (bexpr-some (lambda (x)
                          (and (b-op-p x) (eq (b-op-op x) :call)
                               (scalar-function-test-only (b-op-info x))))
                        e))))

(defun fold-constants (e)
  "E with every constant subexpression whose evaluation succeeds replaced by
a literal of the same type."
  (bexpr-rewrite (lambda (x)
                   (when (foldable-p x)
                     (handler-case (make-b-literal (bexpr-type x) (evaluate-constant x))
                       (pq-error () nil))))
                 e))

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
  "Fold constants in E, then simplify its boolean structure bottom-up."
  (labels ((walk (x)
             (if (b-op-p x)
                 (let* ((args (mapcar #'walk (b-op-args x)))
                        (node (if (every #'eq args (b-op-args x))
                                  x
                                  (make-b-op (bexpr-type x) (b-op-op x) args (b-op-info x)))))
                   (simplify-node node))
                 x)))
    (and e (walk (fold-constants e)))))

(defun simplify-plan (node)
  "Apply SIMPLIFY-EXPR to every expression of the plan NODE."
  (let ((children (mapcar #'simplify-plan (lnode-children node))))
    (flet ((copy-with (&rest slots)
             (let ((copy (copy-structure node)))
               (setf (lnode-children copy) children)
               (loop for (setter value) on slots by #'cddr
                     do (funcall setter copy value))
               copy)))
      (typecase node
        (lp-filter
         (let ((p (simplify-expr (lp-filter-predicate node))))
           (if (boolean-literal-p p t)
               (first children)
               (copy-with (lambda (c v) (setf (lp-filter-predicate c) v)) p))))
        (lp-project
         (copy-with (lambda (c v) (setf (lp-project-exprs c) v))
                    (mapcar #'simplify-expr (lp-project-exprs node))))
        (lp-join
         (let ((c (simplify-expr (lp-join-condition node))))
           (copy-with (lambda (n v) (setf (lp-join-condition n) v))
                      (if (boolean-literal-p c t) nil c))))
        (lp-aggregate
         (copy-with (lambda (c v) (setf (lp-aggregate-group-by c) v))
                    (mapcar #'simplify-expr (lp-aggregate-group-by node))
                    (lambda (c v) (setf (lp-aggregate-aggregates c) v))
                    (mapcar #'simplify-expr (lp-aggregate-aggregates node))))
        (t (rebuild-with-children node children))))))

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
      ;; Conjuncts of the join's own condition come first, so that (as
      ;; without pushdown) conjuncts from above are only evaluated for rows
      ;; satisfying them.
      ;; Conjuncts without column references (constants, outer references)
      ;; stay above the join: a FALSE one then skips the whole join.
      (dolist (c (and (lp-join-condition node) (split-conjuncts (lp-join-condition node))))
        (cond ((and (not outer-join) (null (bexpr-column-indexes c))) (push c above))
              ((and (not outer-join) (columns-within-p c 0 lw)) (push c to-left))
              ((columns-within-p c lw width) (push c to-right))
              (t (push c to-join))))
      ;; Conjuncts from above the join (WHERE or enclosing filters).
      (dolist (c conjuncts)
        (cond ((null (bexpr-column-indexes c)) (push c above))
              ((columns-within-p c 0 lw) (push c to-left))
              (outer-join (push c above))
              ((columns-within-p c lw width) (push c to-right))
              (t (push c to-join))))
      (let ((join (make-join (if (and (eq kind :cross) to-join) :inner kind)
                             (push-conjuncts left (nreverse to-left))
                             (push-conjuncts right (mapcar (lambda (c) (bexpr-shift-columns c (- lw)))
                                                           (nreverse to-right)))
                             (conjoin (nreverse to-join)))))
        (make-filter join (conjoin (nreverse above)))))))

;;; ------------------------------------------------------------------
;;; Join reordering

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
