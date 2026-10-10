;;;; binder.lisp — semantic analysis: name resolution, typing and validation.
;;;;
;;;; Turns the parser's AST into a BOUND-SELECT whose expressions are typed
;;;; B-* nodes. All errors detectable before execution (SEMANTIC_ERROR,
;;;; TYPE_ERROR, invalid literals) are raised here.

(in-package #:polyquery)

;;; ------------------------------------------------------------------
;;; Scopes

(defstruct (relation (:constructor make-relation (name table columns offset)))
  "A range variable of the FROM clause."
  name table
  (columns #() :type simple-vector)   ; of COLUMN-DEF
  (offset 0 :type fixnum))            ; position of its first column in the input row

(defstruct bind-env
  (relations '())                     ; list of RELATION
  (aggregates :forbidden)             ; :ALLOWED, :FORBIDDEN or :INSIDE (an aggregate argument)
  (clause "WHERE")                    ; for error messages
  (test-functions nil))

(defun bind-error-at (node code format-control &rest args)
  "Signal CODE with the source position of the AST NODE in the details."
  (error 'pq-error :code code
                   :message (apply #'format nil format-control args)
                   :details (when (and node (plusp (ast-node-line node)))
                              (list (cons "line" (ast-node-line node))
                                    (cons "column" (ast-node-column node))))))

(defun resolve-column (env node)
  "Resolve an AST-COLUMN-REF to a B-COLUMN."
  (let ((qualifier (ast-column-ref-qualifier node))
        (name (ast-column-ref-name node))
        (matches '()))
    (if qualifier
        (let ((rel (find qualifier (bind-env-relations env)
                         :key #'relation-name :test #'ascii-string-equal)))
          (unless rel
            (bind-error-at node "SEMANTIC_ERROR" "unknown table or alias ~A" qualifier))
          (let ((i (position name (relation-columns rel) :key #'column-def-name
                                                         :test #'ascii-string-equal)))
            (unless i
              (bind-error-at node "SEMANTIC_ERROR" "unknown column ~A.~A" qualifier name))
            (push (cons rel i) matches)))
        (dolist (rel (bind-env-relations env))
          (loop for c across (relation-columns rel)
                for i from 0
                when (ascii-string-equal (column-def-name c) name)
                  do (push (cons rel i) matches))))
    (cond ((and (null matches) (member (bind-env-clause env) '("LIMIT" "OFFSET") :test #'string=))
           (bind-error-at node "SEMANTIC_ERROR" "~A must be a constant expression"
                          (bind-env-clause env)))
          ((null matches)
           (bind-error-at node "SEMANTIC_ERROR" "unknown column ~A" name))
          ((rest matches)
           (bind-error-at node "SEMANTIC_ERROR" "ambiguous column ~A" name))
          (t
           (destructuring-bind (rel . i) (first matches)
             (let ((def (svref (relation-columns rel) i)))
               (make-b-column (column-def-type def) (+ (relation-offset rel) i)
                              (column-def-name def))))))))

;;; ------------------------------------------------------------------
;;; Literals

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
       (let ((ts (parse-timestamp-text v :allow-date-only t)))
         (unless ts (bind-error-at node "CONVERSION_ERROR" "invalid TIMESTAMP literal '~A'" v))
         (make-b-literal :timestamp ts))))))

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

(defun bind-comparison (op left right node)
  (let ((ct (comparison-type (bexpr-type left) (bexpr-type right))))
    (unless ct
      (bind-error-at node "TYPE_ERROR" "cannot compare ~A with ~A"
                     (type-name-string (bexpr-type left)) (type-name-string (bexpr-type right))))
    (make-b-op :boolean op (list left right))))

(defun check-boolean-operand (e what node)
  (unless (member (bexpr-type e) '(:boolean :null))
    (bind-error-at node "TYPE_ERROR" "~A expects BOOLEAN, got ~A" what
                   (type-name-string (bexpr-type e)))))

(defun bind-unary (node env)
  (let* ((operand (bind-expr (ast-unary-operand node) env))
         (type (arithmetic-operand-type (bexpr-type operand))))
    (unless (numeric-type-p type)
      (bind-error-at node "TYPE_ERROR" "unary ~A expects a numeric operand"
                     (if (eq (ast-unary-op node) :neg) "-" "+")))
    (if (eq (ast-unary-op node) :pos)
        (implicit-cast operand type)
        (make-b-op type :neg (list (implicit-cast operand type))))))

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
       (dolist (e (list left right))
         (unless (member (bexpr-type e) '(:string :null))
           (bind-error-at node "TYPE_ERROR" "|| expects STRING operands, got ~A"
                          (type-name-string (bexpr-type e)))))
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

;;; ------------------------------------------------------------------
;;; Function calls and aggregates

(defun aggregate-result-type (fn arg-type node)
  (ecase fn
    ((:count :count-star) :int64)
    (:sum (let ((ty (arithmetic-operand-type arg-type)))
            (unless (numeric-type-p ty)
              (bind-error-at node "TYPE_ERROR" "SUM expects a numeric argument, got ~A"
                             (type-name-string arg-type)))
            (if (decimal-type-p ty) (make-decimal-type 18 (decimal-scale ty)) ty)))
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
           (let* ((inner (copy-bind-env env))
                  (_ (setf (bind-env-aggregates inner) :inside))
                  (arg (bind-expr (first args) inner)))
             (declare (ignore _))
             (make-b-agg (aggregate-result-type fn (bexpr-type arg) node) fn (list arg)
                         (ast-function-distinct node)))))))

(defun bind-function (node env)
  (let ((name (ascii-upcase (ast-function-name node))))
    (if (member name *aggregate-function-names* :test #'string=)
        (bind-aggregate name node env)
        (let ((fn (handler-case (find-scalar-function name (bind-env-test-functions env))
                    (pq-error (e) (bind-error-at node (pq-error-code e) "~A" (pq-error-message e)))))
              (args (ast-function-args node)))
          (when (or (ast-function-star node) (ast-function-distinct node))
            (bind-error-at node "SEMANTIC_ERROR" "~A does not accept * or DISTINCT" name))
          (unless (<= (scalar-function-min-args fn) (length args) (scalar-function-max-args fn))
            (bind-error-at node "SEMANTIC_ERROR" "wrong number of arguments for ~A" name))
          (let* ((bound (mapcar (lambda (a) (bind-expr a env)) args))
                 (type (funcall (scalar-function-typer fn) (mapcar #'bexpr-type bound))))
            (make-b-op type :call bound fn))))))

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
    (ast-between (bind-error-at node "UNSUPPORTED" "BETWEEN is not supported"))
    (ast-in-list (bind-error-at node "UNSUPPORTED" "IN lists are not supported"))
    (ast-in-subquery (bind-error-at node "UNSUPPORTED" "subqueries are not supported"))
    (ast-like (bind-error-at node "UNSUPPORTED" "LIKE is not supported"))
    (ast-case (bind-error-at node "UNSUPPORTED" "CASE is not supported"))
    (ast-exists (bind-error-at node "UNSUPPORTED" "subqueries are not supported"))
    (ast-subquery (bind-error-at node "UNSUPPORTED" "subqueries are not supported"))))

(defun bind-condition (node env clause)
  "Bind a WHERE/HAVING-style condition, which must be BOOLEAN."
  (let ((e (bind-expr node env)))
    (unless (member (bexpr-type e) '(:boolean :null))
      (bind-error-at node "TYPE_ERROR" "~A condition must be BOOLEAN, got ~A"
                     clause (type-name-string (bexpr-type e))))
    e))
