;;;; test-sql.lisp — lexer and parser.

(in-package #:polyquery-tests)

(defun token-kinds (sql)
  (map 'list #'polyquery::token-kind (tokenize sql)))

(deftest lexer.kinds
    (token-kinds "SELECT a, \"b c\", 'x''y', 12, 1.5, 1e3 FROM t -- comment")
  (:keyword :ident :op :qident :op :string :op :integer :op :number :op :number :keyword :ident :eof))

(deftest lexer.operators
    (map 'list #'polyquery::token-value (subseq (tokenize "<= >= <> != || %") 0 6))
  ("<=" ">=" "<>" "!=" "||" "%"))

(deftest lexer.unterminated-string (code-of (tokenize "SELECT 'abc")) "PARSE_ERROR")
(deftest lexer.unterminated-comment (code-of (tokenize "SELECT /* x")) "PARSE_ERROR")
(deftest lexer.bad-char (code-of (tokenize "SELECT @")) "PARSE_ERROR")

(deftest parser.precedence
    (let* ((q (parse-sql "SELECT 1 + 2 * 3"))
           (e (polyquery::ast-select-item-expr
               (first (polyquery::ast-select-items (polyquery::ast-query-body q))))))
      (list (polyquery::ast-binary-op e)
            (polyquery::ast-binary-op (polyquery::ast-binary-right e))))
  (:+ :*))

(deftest parser.negative-literal-folding
    (let* ((q (parse-sql "SELECT -9223372036854775808"))
           (e (polyquery::ast-select-item-expr
               (first (polyquery::ast-select-items (polyquery::ast-query-body q))))))
      (polyquery::ast-literal-value e))
  "-9223372036854775808")

(deftest parser.non-associative (code-of (parse-sql "SELECT 1 = 1 = 1")) "PARSE_ERROR")
(deftest parser.two-statements (code-of (parse-sql "SELECT 1; SELECT 2")) "PARSE_ERROR")
(deftest parser.trailing-semicolon (code-of (parse-sql "SELECT 1;")) :no-error)
(deftest parser.full-grammar
    (code-of (parse-sql "WITH c AS (SELECT a FROM t) SELECT DISTINCT x, COUNT(DISTINCT y) FROM c
                         LEFT JOIN u ON c.a = u.a WHERE x BETWEEN 1 AND 2 AND y IN (1, 2)
                         AND z LIKE 'a%' AND EXISTS (SELECT 1) GROUP BY x HAVING COUNT(*) > 1
                         ORDER BY 1 DESC NULLS LAST LIMIT 5 OFFSET 1"))
  :no-error)
(deftest parser.union (code-of (parse-sql "SELECT 1 UNION SELECT 2")) "UNSUPPORTED")
(deftest parser.count-star-args (code-of (parse-sql "SELECT COUNT(*, id) FROM t")) "PARSE_ERROR")
