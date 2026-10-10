;;;; query.lisp — semantic analysis of whole queries: CTEs, FROM (tables,
;;;; derived tables, joins), select list expansion and naming, grouping and
;;;; aggregation analysis, HAVING, DISTINCT, ORDER BY and LIMIT/OFFSET.

(in-package #:polyquery)

(defun bind-statement (ast catalog &key test-functions)
  "Analyse a parsed statement. Returns a BOUND-QUERY (for EXPLAIN, the
explained query; the caller distinguishes the statement kind)."
  (etypecase ast
    (ast-query (bind-top-level-query ast catalog test-functions))
    (ast-explain (bind-top-level-query (ast-explain-query ast) catalog test-functions))
    ((or ast-create-index ast-drop-index)
     (bind-error-at ast "UNSUPPORTED" "indexes are not supported by this engine"))))

(defun bind-top-level-query (ast catalog test-functions)
  (let ((*subquery-stack* '()))
    (bind-query ast (make-bind-env :catalog catalog :test-functions test-functions))))

;;; ------------------------------------------------------------------
;;; CTEs (semantics.md §9)

(defun bind-cte-list (ctes env)
  "Analyse the CTEs of a WITH clause in order. Returns the list of visible
CTE bindings (innermost first) for the main query."
  (let ((visible (bind-env-ctes env))
        (names '()))
    (dolist (cte ctes visible)
      (let ((name (ast-cte-name cte)))
        (when (member name names :test #'ascii-string-equal)
          (bind-error-at cte "SEMANTIC_ERROR" "duplicate CTE name ~A" name))
        (push name names)
        (let* ((correlated nil)
               (outer (bind-env-outer env))
               (resolver (when outer
                           (lambda (node)
                             (let ((e (funcall outer node)))
                               (when e (setf correlated t))
                               e))))
               ;; The CTE sees earlier CTEs and the enclosing queries, but
               ;; neither itself nor the FROM clause of the query it belongs to.
               (query (bind-query (ast-cte-query cte)
                                  (env-with env :outer resolver :ctes visible :relations '())))
               (columns (bound-query-columns query)))
          (when (ast-cte-columns cte)
            (unless (= (length (ast-cte-columns cte)) (length columns))
              (bind-error-at cte "SEMANTIC_ERROR" "CTE ~A has ~D columns but ~D column names"
                             name (length columns) (length (ast-cte-columns cte))))
            (setf columns (mapcar (lambda (n c) (make-column-def n (column-def-type c)))
                                  (ast-cte-columns cte) columns)))
          (push (make-cte-binding :name name :query query :columns columns
                                  :correlated correlated :depth (length *subquery-stack*))
                visible))))))

(defun note-cte-reference (cte)
  "A CTE correlated with an enclosing query makes every subquery between the
reference and the CTE's definition depend on parameters it does not own:
such subqueries must not cache their results."
  (when (cte-binding-correlated cte)
    (loop for sq in *subquery-stack*
          repeat (- (length *subquery-stack*) (cte-binding-depth cte))
          do (setf (subquery-cacheable sq) nil))))

;;; ------------------------------------------------------------------
;;; FROM (semantics.md §1, §7)

(defun bind-from-clause (ast env)
  "Analyse a FROM item. Returns (values bf-tree relations width)."
  (let ((all '()))
    (labels ((add-relation (node name columns offset)
               (when (find name all :key #'relation-name :test #'ascii-string-equal)
                 (bind-error-at node "SEMANTIC_ERROR" "duplicate range variable ~A in FROM" name))
               (let ((rel (make-relation name (coerce columns 'simple-vector) offset)))
                 (setf all (append all (list rel)))
                 rel))
             (walk (node offset)
               (etypecase node
                 (ast-table-ref
                  (let* ((name (ast-table-ref-name node))
                         (cte (find name (bind-env-ctes env) :key #'cte-binding-name
                                                            :test #'ascii-string-equal)))
                    (if cte
                        (let ((rel (add-relation node (or (ast-table-ref-alias node) (cte-binding-name cte))
                                                 (cte-binding-columns cte) offset)))
                          (note-cte-reference cte)
                          (make-bf-derived :relation rel :query (cte-binding-query cte)
                                           :relation-list (list rel) :offset offset
                                           :width (length (relation-columns rel))))
                        (let ((table (catalog-find-table (bind-env-catalog env) name)))
                          (unless table
                            (bind-error-at node "SEMANTIC_ERROR" "unknown table ~A" name))
                          (let ((rel (add-relation node (or (ast-table-ref-alias node) (table-name table))
                                                   (table-columns table) offset)))
                            (make-bf-table :relation rel :table table :relation-list (list rel)
                                           :offset offset :width (table-column-count table)))))))
                 (ast-derived-table
                  ;; A derived table cannot see the FROM clause it appears in.
                  (let* ((query (bind-query (ast-derived-table-query node)
                                            (env-with env :relations '())))
                         (rel (add-relation node (ast-derived-table-alias node)
                                            (bound-query-columns query) offset)))
                    (make-bf-derived :relation rel :query query :relation-list (list rel)
                                     :offset offset :width (length (relation-columns rel)))))
                 (ast-join
                  (let* ((left (walk (ast-join-left node) offset))
                         (right (walk (ast-join-right node) (+ offset (bf-node-width left))))
                         (rels (append (bf-node-relation-list left) (bf-node-relation-list right)))
                         (condition (when (ast-join-condition node)
                                      (bind-condition (ast-join-condition node)
                                                      (env-with env :relations rels
                                                                    :aggregates :forbidden)
                                                      "ON"))))
                    (make-bf-join :kind (ast-join-kind node) :left left :right right
                                  :condition condition :relation-list rels :offset offset
                                  :width (+ (bf-node-width left) (bf-node-width right))))))))
      (let ((tree (walk ast 0)))
        (values tree all (bf-node-width tree))))))

;;; ------------------------------------------------------------------
;;; Select list (semantics.md §3)

(defun expand-select-items (items env)
  "Bind the select list. Returns a list of (name-or-NIL . bexpr); NIL names
are later replaced by _colN."
  (let ((out '()))
    (dolist (item items (nreverse out))
      (let ((expr (ast-select-item-expr item)))
        (if (ast-star-p expr)
            (let* ((qualifier (ast-star-qualifier expr))
                   (rels (if qualifier
                             (let ((r (find-relation env qualifier)))
                               (unless r
                                 (bind-error-at expr "SEMANTIC_ERROR" "unknown table or alias ~A"
                                                qualifier))
                               (list r))
                             (bind-env-relations env))))
              (when (null rels)
                (bind-error-at expr "SEMANTIC_ERROR" "SELECT * requires a FROM clause"))
              (dolist (rel rels)
                (loop for c across (relation-columns rel)
                      for i from 0
                      do (push (cons (column-def-name c)
                                     (make-b-column (column-def-type c) (+ (relation-offset rel) i)
                                                    (column-def-name c)))
                               out))))
            (let ((bound (bind-expr expr env)))
              (push (cons (cond ((ast-select-item-alias item))
                                ((ast-column-ref-p expr)
                                 (typecase bound
                                   (b-column (b-column-name bound))
                                   (b-param (b-param-name bound))
                                   (t (ast-column-ref-name expr))))
                                (t nil))
                          bound)
                    out)))))))

(defun name-outputs (items)
  (loop for (name . expr) in items
        for i from 1
        collect (cons (or name (format nil "_col~D" i)) expr)))

;;; ------------------------------------------------------------------
;;; Grouping and aggregation (semantics.md §5)

(defun ordinal-literal (node)
  "The value of NODE if it is an unsigned integer literal (an ordinal
reference in GROUP BY / ORDER BY), else NIL."
  (when (and (ast-literal-p node) (eq (ast-literal-kind node) :integer)
             (char/= (char (ast-literal-value node) 0) #\-))
    (parse-int-text (ast-literal-value node))))

(defun bind-group-by-item (node env outputs)
  "A GROUP BY item: an ordinal, a select alias, or an expression over the input."
  (flet ((select-expr (e)
           (when (bexpr-contains-aggregate-p e)
             (bind-error-at node "SEMANTIC_ERROR" "GROUP BY cannot refer to an aggregate"))
           e))
    (let ((k (ordinal-literal node)))
      (cond
        (k (unless (<= 1 k (length outputs))
             (bind-error-at node "SEMANTIC_ERROR" "GROUP BY position ~D is out of range" k))
           (select-expr (cdr (nth (1- k) outputs))))
        ((and (ast-column-ref-p node)
              (null (ast-column-ref-qualifier node))
              (null (lookup-column (env-with env :outer nil) node))
              (find (ast-column-ref-name node) outputs :key #'car :test #'ascii-string-equal))
         (select-expr (cdr (find (ast-column-ref-name node) outputs :key #'car
                                                                    :test #'ascii-string-equal))))
        (t (bind-expr node (env-with env :aggregates :forbidden :clause "GROUP BY")))))))

(defun rewrite-for-aggregation (e group-by aggregates-cell)
  "Rewrite output expression E onto the aggregation row. Subexpressions equal
to a GROUP BY expression become key references, aggregate calls become
references to (deduplicated) aggregate slots collected in AGGREGATES-CELL
(a cons whose car is the list). Remaining input columns are an error."
  (let ((ngroups (length group-by)))
    (bexpr-rewrite
     (lambda (x)
       (let ((k (position x group-by :test #'bexpr-equal)))
         (cond
           (k (make-b-column (bexpr-type x) k (bexpr-describe x)))
           ((b-agg-p x)
            (let ((j (position x (car aggregates-cell) :test #'bexpr-equal)))
              (unless j
                (setf (car aggregates-cell) (append (car aggregates-cell) (list x))
                      j (1- (length (car aggregates-cell)))))
              (make-b-column (bexpr-type x) (+ ngroups j) (bexpr-describe x))))
           ((b-column-p x)
            (semantic-error "column ~A must appear in GROUP BY or be used in an aggregate function"
                            (b-column-name x)))
           (t nil))))
     e)))

;;; ------------------------------------------------------------------
;;; ORDER BY (semantics.md §6)

(defun resolve-order-item (item outputs env distinct)
  "Returns (values output-position-or-NIL bound-expression)."
  (let ((expr (ast-order-item-expr item))
        (k (ordinal-literal (ast-order-item-expr item))))
    (cond
      (k (unless (<= 1 k (length outputs))
           (bind-error-at expr "SEMANTIC_ERROR" "ORDER BY position ~D is out of range" k))
         (values (1- k) nil))
      ((and (ast-column-ref-p expr) (null (ast-column-ref-qualifier expr))
            (find (ast-column-ref-name expr) outputs :key #'car :test #'ascii-string-equal))
       (let ((hits (loop for (name . e) in outputs
                         for i from 0
                         when (ascii-string-equal name (ast-column-ref-name expr))
                           collect (cons i e))))
         (unless (every (lambda (h) (bexpr-equal (cdr h) (cdr (first hits)))) (rest hits))
           (bind-error-at expr "SEMANTIC_ERROR" "ORDER BY ~A is ambiguous" (ast-column-ref-name expr)))
         (values (car (first hits)) nil)))
      (t
       (let* ((bound (bind-expr expr (env-with env :aggregates :allowed :clause "ORDER BY")))
              (pos (position bound outputs :key #'cdr :test #'bexpr-equal)))
         (when (and distinct (null pos))
           (bind-error-at expr "SEMANTIC_ERROR"
                          "ORDER BY expressions must appear in the select list of SELECT DISTINCT"))
         (values pos bound))))))

;;; ------------------------------------------------------------------
;;; LIMIT / OFFSET

(defun bind-constant-int (node what env)
  "A LIMIT/OFFSET expression: a constant INT64 expression (evaluated at execution)."
  (when node
    (let ((e (bind-expr node (make-bind-env :catalog (bind-env-catalog env) :clause what
                                            :test-functions (bind-env-test-functions env)))))
      (unless (bexpr-constant-p e)
        (bind-error-at node "SEMANTIC_ERROR" "~A must be a constant expression" what))
      (unless (member (bexpr-type e) '(:int64 :null))
        (bind-error-at node "TYPE_ERROR" "~A must be INT64" what))
      e)))

;;; ------------------------------------------------------------------
;;; Query

(defun bind-query (ast parent-env)
  "Analyse an AST-QUERY. PARENT-ENV supplies the catalog, the visible CTEs and
the resolver for columns of enclosing queries; its relations are ignored."
  (let* ((env (env-with parent-env :relations '() :aggregates :forbidden :clause "WHERE"))
         (env (env-with env :ctes (bind-cte-list (ast-query-ctes ast) env)))
         (core (ast-query-body ast))
         (distinct (ast-select-distinct core)))
    (multiple-value-bind (from relations from-width)
        (if (ast-select-from core)
            (bind-from-clause (ast-select-from core) env)
            (values nil '() 0))
      (setf env (env-with env :relations relations))
      (let* ((where (when (ast-select-where core)
                      (bind-condition (ast-select-where core) env "WHERE")))
             (select-env (env-with env :aggregates :allowed :clause "SELECT"))
             (outputs (name-outputs (expand-select-items (ast-select-items core) select-env)))
             (group-by (mapcar (lambda (g) (bind-group-by-item g env outputs))
                               (ast-select-group-by core)))
             (having (when (ast-select-having core)
                       (bind-condition (ast-select-having core)
                                       (env-with env :aggregates :allowed) "HAVING")))
             (order '())
             (hidden '()))
        ;; ORDER BY keys are either output positions or extra hidden expressions.
        (dolist (item (ast-query-order-by ast))
          (multiple-value-bind (position expr) (resolve-order-item item outputs env distinct)
            (unless position
              (setf position (+ (length outputs) (length hidden))
                    hidden (append hidden (list expr))))
            (let ((descending (ast-order-item-descending item)))
              (push (list position descending
                          (ecase (ast-order-item-nulls item)
                            (:first t) (:last nil) ((nil) (not descending))))
                    order))))
        (let* ((aggregated (or group-by having
                               (some (lambda (o) (bexpr-contains-aggregate-p (cdr o))) outputs)
                               (some #'bexpr-contains-aggregate-p hidden)))
               (aggregates (list '()))
               (columns (loop for (name . e) in outputs collect (make-column-def name (bexpr-type e)))))
          (when aggregated
            (flet ((rewrite (e) (rewrite-for-aggregation e group-by aggregates)))
              (setf outputs (loop for (name . e) in outputs collect (cons name (rewrite e)))
                    hidden (mapcar #'rewrite hidden)
                    having (and having (rewrite having)))))
          (make-bound-query
           :from from
           :from-width from-width
           :where where
           :aggregated-p (and aggregated t)
           :group-by group-by
           :aggregates (car aggregates)
           :having having
           :outputs (mapcar #'cdr outputs)
           :hidden hidden
           :distinct distinct
           :order (nreverse order)
           :limit (bind-constant-int (ast-query-limit ast) "LIMIT" env)
           :offset (bind-constant-int (ast-query-offset ast) "OFFSET" env)
           :columns columns))))))
