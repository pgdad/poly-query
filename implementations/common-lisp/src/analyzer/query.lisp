;;;; query.lisp — binding of whole SELECT statements: FROM resolution, select
;;;; list expansion and naming, aggregation analysis, ORDER BY and LIMIT.

(in-package #:polyquery)

(defstruct bound-select
  "A fully analysed SELECT. Input-side expressions (WHERE, GROUP BY,
aggregate arguments) index the columns of TABLE. Output-side expressions
(OUTPUTS, HIDDEN) index the input row, or — when AGGREGATED-P — the
aggregation row [group keys..., aggregate values...]."
  table                    ; TABLE or NIL (SELECT without FROM)
  table-label              ; range variable name
  where                    ; BEXPR or NIL
  aggregated-p
  group-by                 ; list of BEXPR
  aggregates               ; list of B-AGG
  outputs                  ; list of (name . BEXPR)
  hidden                   ; list of BEXPR: extra sort keys after the outputs
  order                    ; list of (position descending nulls-first)
  limit offset)            ; integers or NIL

(defun bind-statement (ast catalog &key test-functions)
  "Analyse a parsed statement. Only plain queries are supported in Phase 1."
  (etypecase ast
    (ast-query (bind-query ast catalog :test-functions test-functions))
    (ast-explain (bind-error-at ast "UNSUPPORTED" "EXPLAIN is not supported"))
    ((or ast-create-index ast-drop-index)
     (bind-error-at ast "UNSUPPORTED" "indexes are not supported"))))

(defun bind-from (from catalog)
  "Resolve the FROM clause to a single RELATION (Phase 1: one base table)."
  (etypecase from
    (ast-table-ref
     (let ((table (catalog-find-table catalog (ast-table-ref-name from))))
       (unless table
         (bind-error-at from "SEMANTIC_ERROR" "unknown table ~A" (ast-table-ref-name from)))
       (make-relation (or (ast-table-ref-alias from) (table-name table))
                      table (table-columns table) 0)))
    (ast-join (bind-error-at from "UNSUPPORTED" "joins are not supported"))
    (ast-derived-table (bind-error-at from "UNSUPPORTED" "derived tables are not supported"))))

(defun expand-select-items (items env)
  "Bind the select list. Returns a list of (name-or-NIL . bexpr); NIL names
are later replaced by _colN."
  (let ((out '()))
    (dolist (item items (nreverse out))
      (let ((expr (ast-select-item-expr item)))
        (if (ast-star-p expr)
            (let* ((qualifier (ast-star-qualifier expr))
                   (rels (if qualifier
                             (let ((r (find qualifier (bind-env-relations env)
                                            :key #'relation-name :test #'ascii-string-equal)))
                               (unless r
                                 (bind-error-at expr "SEMANTIC_ERROR" "unknown table or alias ~A" qualifier))
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
                                ((ast-column-ref-p expr) (b-column-name bound))
                                (t nil))
                          bound)
                    out)))))))

(defun name-outputs (items)
  (loop for (name . expr) in items
        for i from 1
        collect (cons (or name (format nil "_col~D" i)) expr)))

(defun constant-int-clause (node what test-functions)
  "Evaluate a LIMIT/OFFSET expression: a constant non-negative INT64."
  (when node
    (when (ast-node-contains-column-ref-p node)
      (bind-error-at node "SEMANTIC_ERROR" "~A must be a constant expression" what))
    (let* ((env (make-bind-env :clause what :test-functions test-functions))
           (e (bind-expr node env)))
      (unless (member (bexpr-type e) '(:int64 :null))
        (bind-error-at node "TYPE_ERROR" "~A must be INT64" what))
      (let ((v (funcall (compile-bexpr e) #())))
        (cond ((null-value-p v) nil)
              ((minusp v) (bind-error-at node "INVALID_ARGUMENT" "~A must not be negative" what))
              (t v))))))

(defun ast-node-contains-column-ref-p (node)
  "Conservative syntactic check used for constant-only clauses."
  (typecase node
    (ast-column-ref t)
    (ast-unary (ast-node-contains-column-ref-p (ast-unary-operand node)))
    (ast-binary (or (ast-node-contains-column-ref-p (ast-binary-left node))
                    (ast-node-contains-column-ref-p (ast-binary-right node))))
    (ast-not (ast-node-contains-column-ref-p (ast-not-operand node)))
    (ast-cast (ast-node-contains-column-ref-p (ast-cast-operand node)))
    (ast-function (some #'ast-node-contains-column-ref-p (ast-function-args node)))
    (ast-is-null (ast-node-contains-column-ref-p (ast-is-null-operand node)))
    (t nil)))

;;; ------------------------------------------------------------------
;;; Aggregation analysis (semantics.md §5)

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
           (k (make-b-column (bexpr-type x) k (when (b-column-p x) (b-column-name x))))
           ((b-agg-p x)
            (let ((j (position x (car aggregates-cell) :test #'bexpr-equal)))
              (unless j
                (setf (car aggregates-cell) (append (car aggregates-cell) (list x))
                      j (1- (length (car aggregates-cell)))))
              (make-b-column (bexpr-type x) (+ ngroups j) nil)))
           ((b-column-p x)
            (semantic-error "column ~A must appear in GROUP BY or be used in an aggregate function"
                            (b-column-name x)))
           (t nil))))
     e)))

;;; ------------------------------------------------------------------
;;; ORDER BY (semantics.md §6)

(defun resolve-order-item (item outputs env)
  "Returns (values output-position-or-NIL bound-expression)."
  (let ((expr (ast-order-item-expr item)))
    (cond
      ((and (ast-literal-p expr) (eq (ast-literal-kind expr) :integer)
            (not (char= (char (ast-literal-value expr) 0) #\-)))
       (let ((k (parse-int-text (ast-literal-value expr))))
         (unless (<= 1 k (length outputs))
           (bind-error-at expr "SEMANTIC_ERROR" "ORDER BY position ~D is out of range" k))
         (values (1- k) nil)))
      ((and (ast-column-ref-p expr) (null (ast-column-ref-qualifier expr)))
       (let ((hits (loop for (name . e) in outputs
                         for i from 0
                         when (ascii-string-equal name (ast-column-ref-name expr))
                           collect (cons i e))))
         (cond ((null hits) (values nil (bind-expr expr env)))
               ((every (lambda (h) (bexpr-equal (cdr h) (cdr (first hits)))) (rest hits))
                (values (car (first hits)) nil))
               (t (bind-error-at expr "SEMANTIC_ERROR" "ORDER BY ~A is ambiguous"
                                 (ast-column-ref-name expr))))))
      (t (values nil (bind-expr expr env))))))

;;; ------------------------------------------------------------------
;;; Query

(defun bind-query (ast catalog &key test-functions)
  (when (ast-query-ctes ast)
    (bind-error-at ast "UNSUPPORTED" "WITH is not supported"))
  (let* ((core (ast-query-body ast))
         (relation (when (ast-select-from core) (bind-from (ast-select-from core) catalog)))
         (env (make-bind-env :relations (if relation (list relation) '())
                             :test-functions test-functions)))
    (when (ast-select-distinct core)
      (bind-error-at core "UNSUPPORTED" "SELECT DISTINCT is not supported"))
    (when (ast-select-group-by core)
      (bind-error-at core "UNSUPPORTED" "GROUP BY is not supported"))
    (when (ast-select-having core)
      (bind-error-at core "UNSUPPORTED" "HAVING is not supported"))
    (let* ((where (when (ast-select-where core)
                    (bind-condition (ast-select-where core)
                                    (let ((e (copy-bind-env env)))
                                      (setf (bind-env-clause e) "WHERE")
                                      e)
                                    "WHERE")))
           (select-env (let ((e (copy-bind-env env)))
                         (setf (bind-env-aggregates e) :allowed
                               (bind-env-clause e) "SELECT")
                         e))
           (outputs (name-outputs (expand-select-items (ast-select-items core) select-env)))
           (order '())
           (hidden '()))
      ;; ORDER BY keys are either output positions or extra hidden expressions.
      (dolist (item (ast-query-order-by ast))
        (multiple-value-bind (position expr) (resolve-order-item item outputs select-env)
          (unless position
            (setf position (+ (length outputs) (length hidden))
                  hidden (append hidden (list expr))))
          (let ((descending (ast-order-item-descending item)))
            (push (list position descending
                        (ecase (ast-order-item-nulls item)
                          (:first t) (:last nil) ((nil) (not descending))))
                  order))))
      (setf order (nreverse order))
      (let* ((group-by '())
             (aggregated (or group-by
                             (some (lambda (o) (bexpr-contains-aggregate-p (cdr o))) outputs)
                             (some #'bexpr-contains-aggregate-p hidden)))
             (aggregates (list '())))
        (when aggregated
          (setf outputs (loop for (name . e) in outputs
                              collect (cons name (rewrite-for-aggregation e group-by aggregates)))
                hidden (loop for e in hidden
                             collect (rewrite-for-aggregation e group-by aggregates))))
        (make-bound-select
         :table (and relation (relation-table relation))
         :table-label (and relation (relation-name relation))
         :where where
         :aggregated-p (and aggregated t)
         :group-by group-by
         :aggregates (car aggregates)
         :outputs outputs
         :hidden hidden
         :order order
         :limit (constant-int-clause (ast-query-limit ast) "LIMIT" test-functions)
         :offset (constant-int-clause (ast-query-offset ast) "OFFSET" test-functions))))))
