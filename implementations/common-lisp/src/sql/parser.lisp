;;;; parser.lisp — recursive-descent parser for the full PolyQuery SQL grammar
;;;; (grammar.md §2). Produces the AST defined in ast.lisp. Syntax that is
;;;; reserved for future use (UNION, FULL/RIGHT joins) raises UNSUPPORTED.

(in-package #:polyquery)

(defconstant +max-nesting-depth+ 400)

(defstruct (parser (:constructor make-parser (tokens)))
  (tokens #() :type simple-vector)
  (pos 0 :type fixnum)
  (depth 0 :type fixnum))

(defun parse-sql (sql)
  "Parse one SQL statement. Returns an AST-QUERY, AST-EXPLAIN,
AST-CREATE-INDEX or AST-DROP-INDEX."
  (let* ((p (make-parser (tokenize sql)))
         (stmt (parse-statement p)))
    (accept-op p ";")
    (unless (eq (token-kind (current p)) :eof)
      (unexpected p))
    stmt))

;;; ------------------------------------------------------------------
;;; Token helpers

(defun current (p) (svref (parser-tokens p) (parser-pos p)))

(defun peek-token (p &optional (k 1))
  (let ((tokens (parser-tokens p)))
    (svref tokens (min (+ (parser-pos p) k) (1- (length tokens))))))

(defun next-token (p)
  (prog1 (current p)
    (unless (eq (token-kind (current p)) :eof)
      (incf (parser-pos p)))))

(defun token-description (tok)
  (case (token-kind tok)
    (:eof "end of input")
    (:keyword (symbol-name (token-value tok)))
    (:string (format nil "string '~A'" (token-value tok)))
    (t (format nil "~S" (token-value tok)))))

(defun unexpected (p &optional expected)
  (let ((tok (current p)))
    (parse-error-at (token-line tok) (token-column tok)
                    "unexpected ~A~@[, expected ~A~]" (token-description tok) expected)))

(defun keyword-p (tok kw)
  (and (eq (token-kind tok) :keyword) (eq (token-value tok) kw)))

(defun op-p (tok op)
  (and (eq (token-kind tok) :op) (string= (token-value tok) op)))

(defun at-keyword (p kw) (keyword-p (current p) kw))
(defun at-op (p op) (op-p (current p) op))

(defun accept-keyword (p kw)
  (when (at-keyword p kw) (next-token p)))

(defun accept-op (p op)
  (when (at-op p op) (next-token p)))

(defun expect-keyword (p kw)
  (or (accept-keyword p kw) (unexpected p (symbol-name kw))))

(defun expect-op (p op)
  (or (accept-op p op) (unexpected p (format nil "'~A'" op))))

(defun at-identifier (p)
  (member (token-kind (current p)) '(:ident :qident)))

(defun expect-identifier (p &optional (what "identifier"))
  (if (at-identifier p)
      (token-value (next-token p))
      (unexpected p what)))

(defmacro with-node-position ((var p) &body body)
  "Bind VAR to the current token so nodes can record its position."
  `(let ((,var (current ,p))) ,@body))

(defun pos-args (tok)
  (list :line (token-line tok) :column (token-column tok)))

(defmacro with-depth ((p) &body body)
  `(progn
     (when (> (incf (parser-depth ,p)) +max-nesting-depth+)
       (let ((tok (current ,p)))
         (parse-error-at (token-line tok) (token-column tok) "expression nested too deeply")))
     (unwind-protect (progn ,@body)
       (decf (parser-depth ,p)))))

;;; ------------------------------------------------------------------
;;; Statements

(defun parse-statement (p)
  (let ((tok (current p)))
    (cond ((keyword-p tok :explain)
           (next-token p)
           (make-ast-explain :query (parse-query p) :line (token-line tok) :column (token-column tok)))
          ((keyword-p tok :create) (parse-create-index p))
          ((keyword-p tok :drop) (parse-drop-index p))
          ((or (keyword-p tok :select) (keyword-p tok :with)) (parse-query p))
          (t (unexpected p "SELECT, WITH, EXPLAIN, CREATE or DROP")))))

(defun parse-create-index (p)
  (with-node-position (tok p)
    (expect-keyword p :create)
    (expect-keyword p :index)
    (let ((if-not-exists (when (accept-keyword p :if)
                           (expect-keyword p :not)
                           (expect-keyword p :exists)
                           t))
          (name (expect-identifier p "index name")))
      (expect-keyword p :on)
      (let ((table (expect-identifier p "table name")))
        (expect-op p "(")
        (let ((column (expect-identifier p "column name")))
          (expect-op p ")")
          (let ((kind :btree))
            (when (accept-keyword p :using)
              (let ((k (and (eq (token-kind (current p)) :ident)
                            (ascii-upcase (token-value (current p))))))
                (cond ((equal k "HASH") (setf kind :hash))
                      ((equal k "BTREE") (setf kind :btree))
                      (t (unexpected p "HASH or BTREE")))
                (next-token p)))
            (apply #'make-ast-create-index :name name :table table :index-column column :kind kind
                                           :if-not-exists if-not-exists (pos-args tok))))))))

(defun parse-drop-index (p)
  (with-node-position (tok p)
    (expect-keyword p :drop)
    (expect-keyword p :index)
    (let ((if-exists (when (accept-keyword p :if) (expect-keyword p :exists) t)))
      (apply #'make-ast-drop-index :name (expect-identifier p "index name") :if-exists if-exists
             (pos-args tok)))))

;;; ------------------------------------------------------------------
;;; Queries

(defun parse-query (p)
  (with-depth (p)
    (with-node-position (tok p)
      (let ((ctes (when (accept-keyword p :with) (parse-cte-list p)))
            (body (parse-select-core p))
            (order-by nil) (limit nil) (offset nil))
        (when (at-keyword p :union)
          (unsupported-error "UNION is not supported"))
        (when (accept-keyword p :order)
          (expect-keyword p :by)
          (setf order-by (parse-comma-list p #'parse-order-item)))
        (cond ((accept-keyword p :limit)
               (setf limit (parse-expr p))
               (when (accept-keyword p :offset)
                 (setf offset (parse-expr p))))
              ((accept-keyword p :offset)
               (setf offset (parse-expr p))
               (when (accept-keyword p :limit)
                 (setf limit (parse-expr p)))))
        (when (at-keyword p :union)
          (unsupported-error "UNION is not supported"))
        (apply #'make-ast-query :ctes ctes :body body :order-by order-by
                                :limit limit :offset offset (pos-args tok))))))

(defun parse-comma-list (p fn)
  (loop collect (funcall fn p)
        while (accept-op p ",")))

(defun parse-cte-list (p)
  (parse-comma-list
   p (lambda (p)
       (with-node-position (tok p)
         (let ((name (expect-identifier p "CTE name"))
               (columns nil))
           (when (accept-op p "(")
             (setf columns (parse-comma-list p (lambda (p) (expect-identifier p "column name"))))
             (expect-op p ")"))
           (expect-keyword p :as)
           (expect-op p "(")
           (let ((query (parse-query p)))
             (expect-op p ")")
             (apply #'make-ast-cte :name name :columns columns :query query (pos-args tok))))))))

(defun parse-select-core (p)
  (with-node-position (tok p)
    (expect-keyword p :select)
    (let ((distinct (cond ((accept-keyword p :distinct) t)
                          ((accept-keyword p :all) nil)
                          (t nil)))
          (items (parse-comma-list p #'parse-select-item))
          (from nil) (where nil) (group-by nil) (having nil))
      (when (accept-keyword p :from)
        (setf from (parse-from-item p)))
      (when (accept-keyword p :where)
        (setf where (parse-expr p)))
      (when (accept-keyword p :group)
        (expect-keyword p :by)
        (setf group-by (parse-comma-list p #'parse-expr)))
      (when (accept-keyword p :having)
        (setf having (parse-expr p)))
      (apply #'make-ast-select :distinct distinct :items items :from from :where where
                               :group-by group-by :having having (pos-args tok)))))

(defun parse-select-item (p)
  (with-node-position (tok p)
    (cond ((accept-op p "*")
           (apply #'make-ast-select-item :expr (apply #'make-ast-star (pos-args tok)) (pos-args tok)))
          ((and (at-identifier p) (op-p (peek-token p 1) ".") (op-p (peek-token p 2) "*"))
           (let ((qualifier (token-value (next-token p))))
             (next-token p) (next-token p)
             (apply #'make-ast-select-item
                    :expr (apply #'make-ast-star :qualifier qualifier (pos-args tok))
                    (pos-args tok))))
          (t
           (let ((expr (parse-expr p))
                 (alias nil))
             (cond ((accept-keyword p :as) (setf alias (expect-identifier p "alias")))
                   ((at-identifier p) (setf alias (token-value (next-token p)))))
             (apply #'make-ast-select-item :expr expr :alias alias (pos-args tok)))))))

(defun parse-order-item (p)
  (with-node-position (tok p)
    (let ((expr (parse-expr p))
          (descending nil)
          (nulls nil))
      (cond ((accept-keyword p :asc))
            ((accept-keyword p :desc) (setf descending t)))
      (when (accept-keyword p :nulls)
        (cond ((accept-keyword p :first) (setf nulls :first))
              ((accept-keyword p :last) (setf nulls :last))
              (t (unexpected p "FIRST or LAST"))))
      (apply #'make-ast-order-item :expr expr :descending descending :nulls nulls (pos-args tok)))))

;;; ------------------------------------------------------------------
;;; FROM

(defun parse-from-item (p)
  (let ((left (parse-table-ref p)))
    (loop
      (with-node-position (tok p)
        (flet ((join (kind right condition)
                 (setf left (apply #'make-ast-join :kind kind :left left :right right
                                                   :condition condition (pos-args tok)))))
          (cond ((accept-op p ",")
                 (join :cross (parse-table-ref p) nil))
                ((accept-keyword p :cross)
                 (expect-keyword p :join)
                 (join :cross (parse-table-ref p) nil))
                ((or (at-keyword p :join) (at-keyword p :inner))
                 (accept-keyword p :inner)
                 (expect-keyword p :join)
                 (let ((right (parse-table-ref p)))
                   (expect-keyword p :on)
                   (join :inner right (parse-expr p))))
                ((accept-keyword p :left)
                 (accept-keyword p :outer)
                 (expect-keyword p :join)
                 (let ((right (parse-table-ref p)))
                   (expect-keyword p :on)
                   (join :left right (parse-expr p))))
                ((or (at-keyword p :right) (at-keyword p :full))
                 (unsupported-error "RIGHT and FULL joins are not supported"))
                (t (return left))))))))

(defun parse-table-ref (p)
  (with-depth (p)
    (with-node-position (tok p)
      (cond
        ((at-op p "(")
         (let ((next (peek-token p 1)))
           (next-token p)
           (if (or (keyword-p next :select) (keyword-p next :with))
               (let ((query (parse-query p)))
                 (expect-op p ")")
                 (accept-keyword p :as)
                 (apply #'make-ast-derived-table :query query
                                                 :alias (expect-identifier p "derived table alias")
                                                 (pos-args tok)))
               (let ((item (parse-from-item p)))
                 (expect-op p ")")
                 item))))
        (t
         (let ((name (expect-identifier p "table name"))
               (alias nil))
           (cond ((accept-keyword p :as) (setf alias (expect-identifier p "alias")))
                 ((at-identifier p) (setf alias (token-value (next-token p)))))
           (apply #'make-ast-table-ref :name name :alias alias (pos-args tok))))))))

;;; ------------------------------------------------------------------
;;; Expressions (lowest to highest precedence)

(defun parse-expr (p)
  (with-depth (p)
    (parse-or p)))

(defun parse-or (p)
  (let ((left (parse-and p)))
    (loop
      (with-node-position (tok p)
        (if (accept-keyword p :or)
            (setf left (apply #'make-ast-binary :op :or :left left :right (parse-and p) (pos-args tok)))
            (return left))))))

(defun parse-and (p)
  (let ((left (parse-not p)))
    (loop
      (with-node-position (tok p)
        (if (accept-keyword p :and)
            (setf left (apply #'make-ast-binary :op :and :left left :right (parse-not p) (pos-args tok)))
            (return left))))))

(defun parse-not (p)
  (with-node-position (tok p)
    (if (accept-keyword p :not)
        (with-depth (p)
          (apply #'make-ast-not :operand (parse-not p) (pos-args tok)))
        (parse-predicate p))))

(defparameter *comparison-ops*
  '(("=" . :=) ("<>" . :<>) ("!=" . :<>) ("<" . :<) ("<=" . :<=) (">" . :>) (">=" . :>=)))

(defun parse-predicate (p)
  (let ((left (parse-concat p)))
    (with-node-position (tok p)
      (let ((pos (pos-args tok)))
        (cond
          ((and (eq (token-kind tok) :op) (assoc (token-value tok) *comparison-ops* :test #'string=))
           (next-token p)
           (apply #'make-ast-binary :op (cdr (assoc (token-value tok) *comparison-ops* :test #'string=))
                                    :left left :right (parse-concat p) pos))
          ((accept-keyword p :is)
           (let ((negated (and (accept-keyword p :not) t)))
             (expect-keyword p :null)
             (apply #'make-ast-is-null :operand left :negated negated pos)))
          (t
           (let ((negated nil))
             (when (and (at-keyword p :not)
                        (let ((next (peek-token p 1)))
                          (or (keyword-p next :between) (keyword-p next :in) (keyword-p next :like))))
               (next-token p)
               (setf negated t))
             (cond
               ((accept-keyword p :between)
                (let ((low (parse-concat p)))
                  (expect-keyword p :and)
                  (apply #'make-ast-between :operand left :low low :high (parse-concat p)
                                            :negated negated pos)))
               ((accept-keyword p :in)
                (expect-op p "(")
                (if (or (at-keyword p :select) (at-keyword p :with))
                    (let ((query (parse-query p)))
                      (expect-op p ")")
                      (apply #'make-ast-in-subquery :operand left :query query :negated negated pos))
                    (let ((items (parse-comma-list p #'parse-expr)))
                      (expect-op p ")")
                      (apply #'make-ast-in-list :operand left :items items :negated negated pos))))
               ((accept-keyword p :like)
                (apply #'make-ast-like :operand left :pattern (parse-concat p) :negated negated pos))
               (t left)))))))))

(defun parse-binary-level (p next-fn ops)
  "Parse a left-associative level whose operators are the alist OPS."
  (let ((left (funcall next-fn p)))
    (loop
      (with-node-position (tok p)
        (let ((entry (and (eq (token-kind tok) :op)
                          (assoc (token-value tok) ops :test #'string=))))
          (if entry
              (progn
                (next-token p)
                (setf left (apply #'make-ast-binary :op (cdr entry) :left left
                                                    :right (funcall next-fn p) (pos-args tok))))
              (return left)))))))

(defun parse-concat (p)
  (parse-binary-level p #'parse-additive '(("||" . :concat))))

(defun parse-additive (p)
  (parse-binary-level p #'parse-multiplicative '(("+" . :+) ("-" . :-))))

(defun parse-multiplicative (p)
  (parse-binary-level p #'parse-unary '(("*" . :*) ("/" . :/) ("%" . :%))))

(defun parse-unary (p)
  (with-node-position (tok p)
    (cond
      ((or (at-op p "-") (at-op p "+"))
       (next-token p)
       (let ((op (if (string= (token-value tok) "-") :neg :pos)))
         (with-depth (p)
           ;; Fold a minus sign applied to an (unsigned, possibly parenthesized)
           ;; integer literal so that -9223372036854775808 is representable
           ;; (types.md §3).
           (let ((operand (parse-unary p)))
             (if (and (eq op :neg)
                      (ast-literal-p operand)
                      (eq (ast-literal-kind operand) :integer)
                      (char/= (char (ast-literal-value operand) 0) #\-))
                 (apply #'make-ast-literal :kind :integer
                                           :value (concatenate 'string "-" (ast-literal-value operand))
                                           (pos-args tok))
                 (apply #'make-ast-unary :op op :operand operand (pos-args tok)))))))
      (t (parse-primary p)))))

(defun parse-primary (p)
  (with-node-position (tok p)
    (let ((pos (pos-args tok)))
      (case (token-kind tok)
        (:integer (next-token p) (apply #'make-ast-literal :kind :integer :value (token-value tok) pos))
        (:number (next-token p) (apply #'make-ast-literal :kind :number :value (token-value tok) pos))
        (:string (next-token p) (apply #'make-ast-literal :kind :string :value (token-value tok) pos))
        (:keyword
         (case (token-value tok)
           (:true (next-token p) (apply #'make-ast-literal :kind :boolean :value t pos))
           (:false (next-token p) (apply #'make-ast-literal :kind :boolean :value nil pos))
           (:null (next-token p) (apply #'make-ast-literal :kind :null :value nil pos))
           ((:date :timestamp)
            (next-token p)
            (unless (eq (token-kind (current p)) :string)
              (unexpected p "string literal"))
            (apply #'make-ast-literal :kind (token-value tok)
                                      :value (token-value (next-token p)) pos))
           (:cast (parse-cast p))
           (:case (parse-case p))
           (:exists
            (next-token p)
            (expect-op p "(")
            (let ((query (parse-query p)))
              (expect-op p ")")
              (apply #'make-ast-exists :query query pos)))
           (t (unexpected p "expression"))))
        ((:ident :qident)
         (next-token p)
         (cond
           ((and (eq (token-kind tok) :ident) (at-op p "("))
            (parse-function-call p tok))
           ((accept-op p ".")
            (apply #'make-ast-column-ref :qualifier (token-value tok)
                                         :name (expect-identifier p "column name") pos))
           (t (apply #'make-ast-column-ref :name (token-value tok) pos))))
        (:op
         (if (at-op p "(")
             (progn
               (next-token p)
               (if (or (at-keyword p :select) (at-keyword p :with))
                   (let ((query (parse-query p)))
                     (expect-op p ")")
                     (apply #'make-ast-subquery :query query pos))
                   (let ((e (parse-expr p)))
                     (expect-op p ")")
                     e)))
             (unexpected p "expression")))
        (t (unexpected p "expression"))))))

(defun parse-function-call (p name-token)
  (expect-op p "(")
  (let ((pos (pos-args name-token))
        (name (token-value name-token)))
    (cond ((accept-op p "*")
           (expect-op p ")")
           (apply #'make-ast-function :name name :star t pos))
          ((accept-op p ")")
           (apply #'make-ast-function :name name :args nil pos))
          (t
           (let* ((distinct (and (accept-keyword p :distinct) t))
                  (args (parse-comma-list p #'parse-expr)))
             (expect-op p ")")
             (apply #'make-ast-function :name name :args args :distinct distinct pos))))))

(defun parse-cast (p)
  (with-node-position (tok p)
    (expect-keyword p :cast)
    (expect-op p "(")
    (let ((operand (parse-expr p)))
      (expect-keyword p :as)
      (let* ((type-tok (current p))
             (type-name (cond ((member (token-kind type-tok) '(:ident :qident))
                               (next-token p) (token-value type-tok))
                              ((or (keyword-p type-tok :date) (keyword-p type-tok :timestamp))
                               (next-token p) (symbol-name (token-value type-tok)))
                              (t (unexpected p "type name"))))
             (params nil))
        (when (accept-op p "(")
          (setf params (parse-comma-list
                        p (lambda (p)
                            (unless (eq (token-kind (current p)) :integer)
                              (unexpected p "integer"))
                            (parse-integer (token-value (next-token p))))))
          (expect-op p ")"))
        (expect-op p ")")
        (apply #'make-ast-cast :operand operand :type-name type-name :type-params params
               (pos-args tok))))))

(defun parse-case (p)
  (with-node-position (tok p)
    (expect-keyword p :case)
    (let ((operand (unless (at-keyword p :when) (parse-expr p)))
          (whens '())
          (else nil))
      (unless (at-keyword p :when) (unexpected p "WHEN"))
      (loop while (accept-keyword p :when)
            do (let ((c (parse-expr p)))
                 (expect-keyword p :then)
                 (push (cons c (parse-expr p)) whens)))
      (when (accept-keyword p :else)
        (setf else (parse-expr p)))
      (expect-keyword p :end)
      (apply #'make-ast-case :operand operand :whens (nreverse whens) :else else (pos-args tok)))))
