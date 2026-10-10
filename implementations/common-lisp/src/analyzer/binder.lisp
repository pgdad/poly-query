;;;; binder.lisp — semantic analysis of expressions: name resolution, typing
;;;; and validation.
;;;;
;;;; Turns AST expressions into typed B-* nodes. All errors detectable before
;;;; execution (SEMANTIC_ERROR, TYPE_ERROR, invalid literals) are raised here.
;;;; Query-level analysis (FROM, grouping, ORDER BY, ...) is in query.lisp.

(in-package #:polyquery)

;;; ------------------------------------------------------------------
;;; Scopes

(defstruct (relation (:constructor make-relation (name columns offset)))
  "A range variable of a FROM clause."
  name
  (columns #() :type simple-vector)   ; of COLUMN-DEF
  (offset 0 :type fixnum))            ; position of its first column in the FROM row

(defstruct cte-binding
  "A CTE visible to a query: its analysed query and output columns."
  name
  query                               ; BOUND-QUERY
  columns                             ; list of COLUMN-DEF (after renaming)
  (correlated nil)                    ; references columns of enclosing queries
  (depth 0))                          ; subquery nesting depth of its definition

(defstruct bind-env
  catalog
  (relations '())                     ; RELATIONs visible to column references
  (outer nil)                         ; function (AST-COLUMN-REF) -> BEXPR or NIL: enclosing queries
  (ctes '())                          ; CTE-BINDINGs, innermost first
  (aggregates :forbidden)             ; :ALLOWED, :FORBIDDEN or :INSIDE (an aggregate argument)
  (clause "WHERE")                    ; for error messages
  (test-functions nil))

(defvar *subquery-stack* '()
  "SUBQUERY descriptors whose bodies are being analysed, innermost first.")

(defun env-with (env &rest changes)
  "Copy of ENV with the slots given as keyword/value CHANGES replaced."
  (let ((e (copy-bind-env env)))
    (loop for (key value) on changes by #'cddr
          do (ecase key
               (:relations (setf (bind-env-relations e) value))
               (:outer (setf (bind-env-outer e) value))
               (:ctes (setf (bind-env-ctes e) value))
               (:aggregates (setf (bind-env-aggregates e) value))
               (:clause (setf (bind-env-clause e) value))))
    e))

(defun node-position-details (node)
  (when (and node (plusp (ast-node-line node)))
    (list (cons "line" (ast-node-line node))
          (cons "column" (ast-node-column node)))))

(defun bind-error-at (node code format-control &rest args)
  "Signal CODE with the source position of the AST NODE in the details."
  (error 'pq-error :code code
                   :message (apply #'format nil format-control args)
                   :details (node-position-details node)))

(defmacro with-error-position ((node) &body body)
  "Attach NODE's position to PQ-ERRORs without details signalled in BODY."
  (let ((n (gensym)))
    `(let ((,n ,node))
       (handler-bind ((pq-error (lambda (e)
                                  (unless (pq-error-details e)
                                    (setf (slot-value e 'details) (node-position-details ,n))))))
         ,@body))))

(defun find-relation (env name)
  (find name (bind-env-relations env) :key #'relation-name :test #'ascii-string-equal))

(defun lookup-column (env node)
  "Resolve an AST-COLUMN-REF in ENV and, failing that, in the enclosing
queries. Returns a B-COLUMN (or a B-PARAM for an outer column), or NIL if
the name is unknown everywhere. Ambiguous references are SEMANTIC_ERROR."
  (let* ((qualifier (ast-column-ref-qualifier node))
         (name (ast-column-ref-name node))
         (rels (if qualifier
                   (let ((rel (find-relation env qualifier))) (and rel (list rel)))
                   (bind-env-relations env)))
         (matches '()))
    (dolist (rel rels)
      (loop for c across (relation-columns rel)
            for i from 0
            when (ascii-string-equal (column-def-name c) name)
              do (push (cons rel i) matches)))
    (cond ((rest matches)
           (bind-error-at node "SEMANTIC_ERROR" "ambiguous column ~@[~A.~]~A"
                          qualifier name))
          (matches
           (destructuring-bind (rel . i) (first matches)
             (let ((def (svref (relation-columns rel) i)))
               (make-b-column (column-def-type def) (+ (relation-offset rel) i)
                              (column-def-name def)))))
          ((and qualifier rels)
           (bind-error-at node "SEMANTIC_ERROR" "unknown column ~A.~A" qualifier name))
          ((bind-env-outer env) (funcall (bind-env-outer env) node))
          (t nil))))

(defun resolve-column (env node)
  (or (lookup-column env node)
      (let ((qualifier (ast-column-ref-qualifier node))
            (name (ast-column-ref-name node))
            (clause (bind-env-clause env)))
        (cond ((member clause '("LIMIT" "OFFSET") :test #'string=)
               (bind-error-at node "SEMANTIC_ERROR" "~A must be a constant expression" clause))
              (qualifier
               (bind-error-at node "SEMANTIC_ERROR" "unknown table or alias ~A" qualifier))
              (t (bind-error-at node "SEMANTIC_ERROR" "unknown column ~A" name))))))

;;; ------------------------------------------------------------------
;;; Literals and constants

(defun bind-number-literal (text node)
  (if (find-if (lambda (c) (char-equal c #\e)) text)
      (multiple-value-bind (d status) (parse-float-text text)
        (if (eq status :ok)
            (make-b-literal :float64 d)
            (bind-error-at node "NUMERIC_OVERFLOW" "float literal ~A out of range" text)))
      (multiple-value-bind (unscaled scale) (parse-decimal-text text)
        (let* ((dot (position #\. text))
               (int-part (string-left-trim "0" (subseq text 0 dot)))
               (precision (max (+ (length int-part) scale) scale 1)))
          (if (> precision +max-decimal-precision+)
              (make-b-literal :float64 (parse-float-text text))
              (make-b-literal (make-decimal-type precision scale) unscaled))))))

(defun bind-literal (node)
  (let ((v (ast-literal-value node)))
    (ecase (ast-literal-kind node)
      (:integer
       (let ((n (parse-int-text v)))
         (unless (int64-p n)
           (bind-error-at node "NUMERIC_OVERFLOW" "integer literal ~A out of INT64 range" v))
         (make-b-literal :int64 n)))
      (:number (bind-number-literal v node))
      (:string (make-b-literal :string v))
      (:boolean (make-b-literal :boolean v))
      (:null (make-b-literal :null +null+))
      (:date
       (let ((d (parse-date-text v)))
         (unless d (bind-error-at node "CONVERSION_ERROR" "invalid DATE literal '~A'" v))
         (make-b-literal :date d)))
      (:timestamp
       (let ((ts (parse-timestamp-text v)))
         (unless ts (bind-error-at node "CONVERSION_ERROR" "invalid TIMESTAMP literal '~A'" v))
         (make-b-literal :timestamp ts))))))

(defun evaluate-constant (e)
  "Value of the constant expression E (see BEXPR-CONSTANT-P)."
  (funcall (the function (compile-bexpr e)) #()))

;;; ------------------------------------------------------------------
;;; Operators

(defun implicit-cast (e type)
  "Wrap E in a promotion to TYPE unless it already has that type."
  (if (type-equal (bexpr-type e) type)
      e
      (make-b-op type :cast (list e))))

(defun arithmetic-operand-type (type)
  "The NULL literal behaves as INT64 in arithmetic."
  (if (null-type-p type) :int64 type))

(defun bind-arithmetic (op left right node)
  (let ((lt (arithmetic-operand-type (bexpr-type left)))
        (rt (arithmetic-operand-type (bexpr-type right))))
    (unless (and (numeric-type-p lt) (numeric-type-p rt))
      (bind-error-at node "TYPE_ERROR" "operator ~A expects numeric operands, got ~A and ~A"
                     (symbol-name op) (type-name-string (bexpr-type left))
                     (type-name-string (bexpr-type right))))
    (let ((lk (type-kind lt)) (rk (type-kind rt)))
      (cond
        ((and (null-type-p (bexpr-type left)) (null-type-p (bexpr-type right)))
         ;; Nothing determines a type: the result keeps the null type.
         (make-b-literal :null +null+))
        ((and (eq lk :int64) (eq rk :int64))
         (make-b-op :int64 op (list (implicit-cast left :int64) (implicit-cast right :int64))))
        ((eq op :%)
         (bind-error-at node "TYPE_ERROR" "operator % requires INT64 operands"))
        ((or (eq lk :float64) (eq rk :float64) (eq op :/))
         (make-b-op :float64 op (list (implicit-cast left :float64) (implicit-cast right :float64))))
        (t
         ;; DECIMAL arithmetic: INT64 operands become DECIMAL(18,0); each
         ;; operand keeps its own scale.
         (let* ((l (if (eq lk :int64) (implicit-cast left (make-decimal-type 18 0)) left))
                (r (if (eq rk :int64) (implicit-cast right (make-decimal-type 18 0)) right))
                (ls (decimal-scale (if (eq lk :int64) (make-decimal-type 18 0) lt)))
                (rs (decimal-scale (if (eq rk :int64) (make-decimal-type 18 0) rt))))
           (ecase op
             ((:+ :-) (make-b-op (make-decimal-type 18 (max ls rs)) op (list l r)))
             (:* (when (> (+ ls rs) +max-decimal-precision+)
                   (bind-error-at node "TYPE_ERROR" "DECIMAL product scale ~D exceeds 18" (+ ls rs)))
                 (make-b-op (make-decimal-type 18 (+ ls rs)) op (list l r))))))))))

(defun check-comparable (left right node &optional (what "compare"))
  (unless (comparison-type (bexpr-type left) (bexpr-type right))
    (bind-error-at node "TYPE_ERROR" "cannot ~A ~A with ~A" what
                   (type-name-string (bexpr-type left)) (type-name-string (bexpr-type right)))))

(defun bind-comparison (op left right node)
  (check-comparable left right node)
  (make-b-op :boolean op (list left right)))

(defun check-boolean-operand (e what node)
  (unless (member (bexpr-type e) '(:boolean :null))
    (bind-error-at node "TYPE_ERROR" "~A expects BOOLEAN, got ~A" what
                   (type-name-string (bexpr-type e)))))

(defun check-string-operand (e what node)
  (unless (member (bexpr-type e) '(:string :null))
    (bind-error-at node "TYPE_ERROR" "~A expects STRING operands, got ~A" what
                   (type-name-string (bexpr-type e)))))

(defun bind-unary (node env)
  (let* ((operand (bind-expr (ast-unary-operand node) env))
         (type (arithmetic-operand-type (bexpr-type operand))))
    (unless (numeric-type-p type)
      (bind-error-at node "TYPE_ERROR" "unary ~A expects a numeric operand"
                     (if (eq (ast-unary-op node) :neg) "-" "+")))
    (cond
      ((null-type-p (bexpr-type operand)) operand)
      ((eq (ast-unary-op node) :pos) (implicit-cast operand type))
      (t (make-b-op type :neg (list (implicit-cast operand type)))))))

(defun bind-binary (node env)
  (let* ((op (ast-binary-op node))
         (left (bind-expr (ast-binary-left node) env))
         (right (bind-expr (ast-binary-right node) env)))
    (case op
      ((:+ :- :* :/ :%) (bind-arithmetic op left right node))
      ((:= :<> :< :<= :> :>=) (bind-comparison op left right node))
      ((:and :or)
       (check-boolean-operand left (symbol-name op) node)
       (check-boolean-operand right (symbol-name op) node)
       (make-b-op :boolean op (list left right)))
      (:concat
       (check-string-operand left "||" node)
       (check-string-operand right "||" node)
       (make-b-op :string :concat (list left right))))))

(defun bind-cast (node env)
  (let* ((operand (bind-expr (ast-cast-operand node) env))
         (target (handler-case (resolve-type-name (ast-cast-type-name node)
                                                  (ast-cast-type-params node) "SEMANTIC_ERROR")
                   (pq-error (e) (bind-error-at node "SEMANTIC_ERROR" "~A" (pq-error-message e))))))
    (unless (cast-supported-p (bexpr-type operand) target)
      (bind-error-at node "TYPE_ERROR" "cannot cast ~A to ~A"
                     (type-name-string (bexpr-type operand)) (type-name-string target)))
    (make-b-op target :cast (list operand))))

(defun negate-if (negated e)
  (if negated (make-b-op :boolean :not (list e)) e))

(defun bind-between (node env)
  (let ((x (bind-expr (ast-between-operand node) env))
        (low (bind-expr (ast-between-low node) env))
        (high (bind-expr (ast-between-high node) env)))
    (check-comparable x low node)
    (check-comparable x high node)
    (negate-if (ast-between-negated node) (make-b-op :boolean :between (list x low high)))))

(defun bind-in-list (node env)
  (let ((x (bind-expr (ast-in-list-operand node) env))
        (items (mapcar (lambda (i) (bind-expr i env)) (ast-in-list-items node))))
    (dolist (item items) (check-comparable x item node))
    (negate-if (ast-in-list-negated node) (make-b-op :boolean :in-list (cons x items)))))

(defun bind-like (node env)
  (let ((s (bind-expr (ast-like-operand node) env))
        (p (bind-expr (ast-like-pattern node) env)))
    (check-string-operand s "LIKE" node)
    (check-string-operand p "LIKE" node)
    (negate-if (ast-like-negated node) (make-b-op :boolean :like (list s p)))))

(defun bind-case (node env)
  "CASE becomes a :CASE op with ARGS (operand? cond1 result1 ... [else]) and
INFO (simple-p else-p). Results are cast to their common type."
  (let* ((operand (when (ast-case-operand node) (bind-expr (ast-case-operand node) env)))
         (conditions '()) (results '()))
    (loop for (c . r) in (ast-case-whens node)
          do (let ((bc (bind-expr c env)))
               (if operand
                   (check-comparable operand bc c)
                   (check-boolean-operand bc "CASE WHEN" c))
               (push bc conditions)
               (push (bind-expr r env) results)))
    (setf conditions (nreverse conditions) results (nreverse results))
    (let* ((else (when (ast-case-else node) (bind-expr (ast-case-else node) env)))
           (branches (if else (append results (list else)) results))
           (type (unify-result-types (mapcar #'bexpr-type branches))))
      (unless type
        (bind-error-at node "TYPE_ERROR" "CASE branches have incompatible types ~{~A~^, ~}"
                       (mapcar (lambda (b) (type-name-string (bexpr-type b))) branches)))
      (flet ((cast (e) (implicit-cast e type)))
        (make-b-op type :case
                   (append (when operand (list operand))
                           (loop for c in conditions
                                 for r in results
                                 collect c collect (cast r))
                           (when else (list (cast else))))
                   (list (and operand t) (and else t)))))))

;;; ------------------------------------------------------------------
;;; Subqueries in expressions

(defun bind-subquery (query-ast env kind)
  "Analyse a subquery used as an expression inside ENV. Column references the
subquery cannot resolve itself are looked up in ENV and become correlation
parameters. Returns (values SUBQUERY parameter-expressions)."
  (let* ((sq (make-subquery :kind kind))
         (params '())
         (resolver (lambda (node)
                     (let ((e (lookup-column env node)))
                       (when e
                         (let ((k (position e params :test #'bexpr-equal)))
                           (unless k
                             (setf params (append params (list e))
                                   k (1- (length params))))
                           (make-b-param (bexpr-type e) (subquery-param-env sq) k
                                         (typecase e
                                           (b-column (b-column-name e))
                                           (b-param (b-param-name e))
                                           (t (ast-column-ref-name node))))))))))
    (let ((bq (let ((*subquery-stack* (cons sq *subquery-stack*)))
                (bind-query query-ast (env-with env :outer resolver :relations '())))))
      (setf (subquery-query sq) bq
            (subquery-param-count sq) (length params))
      (values sq params))))

(defun subquery-columns (sq)
  (bound-query-columns (subquery-query sq)))

(defun bind-scalar-subquery (node env)
  (multiple-value-bind (sq params) (bind-subquery (ast-subquery-query node) env :scalar)
    (let ((columns (subquery-columns sq)))
      (unless (= (length columns) 1)
        (bind-error-at node "SEMANTIC_ERROR" "scalar subquery must return exactly one column"))
      (make-b-op (column-def-type (first columns)) :subquery params sq))))

(defun bind-exists (node env)
  (multiple-value-bind (sq params) (bind-subquery (ast-exists-query node) env :exists)
    (make-b-op :boolean :subquery params sq)))

(defun bind-in-subquery (node env)
  (let ((x (bind-expr (ast-in-subquery-operand node) env)))
    (multiple-value-bind (sq params) (bind-subquery (ast-in-subquery-query node) env :in)
      (let ((columns (subquery-columns sq)))
        (unless (= (length columns) 1)
          (bind-error-at node "SEMANTIC_ERROR" "IN subquery must return exactly one column"))
        (unless (comparison-type (bexpr-type x) (column-def-type (first columns)))
          (bind-error-at node "TYPE_ERROR" "cannot compare ~A with IN subquery of ~A"
                         (type-name-string (bexpr-type x))
                         (type-name-string (column-def-type (first columns)))))
        (negate-if (ast-in-subquery-negated node)
                   (make-b-op :boolean :subquery (cons x params) sq))))))

;;; ------------------------------------------------------------------
;;; Function calls and aggregates

(defun aggregate-result-type (fn arg-type node)
  (ecase fn
    ((:count :count-star) :int64)
    (:sum (let ((ty (arithmetic-operand-type arg-type)))
            (unless (numeric-type-p ty)
              (bind-error-at node "TYPE_ERROR" "SUM expects a numeric argument, got ~A"
                             (type-name-string arg-type)))
            (cond ((null-type-p arg-type) :null)
                  ((decimal-type-p ty) (make-decimal-type 18 (decimal-scale ty)))
                  (t ty))))
    (:avg (unless (numeric-type-p (arithmetic-operand-type arg-type))
            (bind-error-at node "TYPE_ERROR" "AVG expects a numeric argument, got ~A"
                           (type-name-string arg-type)))
          :float64)
    ((:min :max) arg-type)))

(defun bind-aggregate (name node env)
  (case (bind-env-aggregates env)
    (:forbidden (bind-error-at node "SEMANTIC_ERROR" "aggregate ~A is not allowed in ~A"
                               name (bind-env-clause env)))
    (:inside (bind-error-at node "SEMANTIC_ERROR" "aggregate calls cannot be nested")))
  (let ((args (ast-function-args node))
        (fn (intern name :keyword)))
    (cond ((ast-function-star node)
           (unless (eq fn :count)
             (bind-error-at node "SEMANTIC_ERROR" "~A(*) is not valid" name))
           (make-b-agg :int64 :count-star nil nil))
          (t
           (unless (= (length args) 1)
             (bind-error-at node "SEMANTIC_ERROR" "~A expects exactly one argument" name))
           (let ((arg (bind-expr (first args) (env-with env :aggregates :inside))))
             (make-b-agg (aggregate-result-type fn (bexpr-type arg) node) fn (list arg)
                         (ast-function-distinct node)))))))

(defun bind-function (node env)
  (let ((name (ascii-upcase (ast-function-name node))))
    (if (member name *aggregate-function-names* :test #'string=)
        (bind-aggregate name node env)
        (let ((fn (with-error-position (node)
                    (find-scalar-function name (bind-env-test-functions env))))
              (args (ast-function-args node)))
          (when (or (ast-function-star node) (ast-function-distinct node))
            (bind-error-at node "SEMANTIC_ERROR" "~A does not accept * or DISTINCT" name))
          (unless (<= (scalar-function-min-args fn) (length args) (scalar-function-max-args fn))
            (bind-error-at node "SEMANTIC_ERROR" "wrong number of arguments for ~A" name))
          (let ((bound (mapcar (lambda (a) (bind-expr a env)) args)))
            (multiple-value-bind (type new-args)
                (with-error-position (node) (funcall (scalar-function-typer fn) bound))
              (make-b-op type :call (or new-args bound) fn)))))))

;;; ------------------------------------------------------------------
;;; Expression dispatcher

(defun bind-expr (node env)
  (etypecase node
    (ast-literal (bind-literal node))
    (ast-column-ref (resolve-column env node))
    (ast-unary (bind-unary node env))
    (ast-binary (bind-binary node env))
    (ast-not
     (let ((operand (bind-expr (ast-not-operand node) env)))
       (check-boolean-operand operand "NOT" node)
       (make-b-op :boolean :not (list operand))))
    (ast-is-null
     (make-b-op :boolean (if (ast-is-null-negated node) :is-not-null :is-null)
                (list (bind-expr (ast-is-null-operand node) env))))
    (ast-cast (bind-cast node env))
    (ast-function (bind-function node env))
    (ast-star (bind-error-at node "SEMANTIC_ERROR" "* is not valid here"))
    (ast-between (bind-between node env))
    (ast-in-list (bind-in-list node env))
    (ast-like (bind-like node env))
    (ast-case (bind-case node env))
    (ast-in-subquery (bind-in-subquery node env))
    (ast-exists (bind-exists node env))
    (ast-subquery (bind-scalar-subquery node env))))

(defun bind-condition (node env clause)
  "Bind a WHERE/HAVING/ON condition, which must be BOOLEAN."
  (let ((e (bind-expr node (env-with env :clause clause))))
    (unless (member (bexpr-type e) '(:boolean :null))
      (bind-error-at node "TYPE_ERROR" "~A condition must be BOOLEAN, got ~A"
                     clause (type-name-string (bexpr-type e))))
    e))
