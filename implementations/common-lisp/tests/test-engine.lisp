;;;; test-engine.lisp — end-to-end SQL evaluation through the engine facade.

(in-package #:polyquery-tests)

(defun eval-sql (sql)
  "Evaluate SQL without tables; return the first row as a list, or the error code."
  (let ((session (make-session (make-engine-config :data-dir "/nonexistent/"))))
    (handler-case
        (coerce (first (polyquery::query-result-rows (execute-sql session sql))) 'list)
      (pq-error (e) (pq-error-code e)))))

(deftest eval.int-arith (eval-sql "SELECT 7 / 2, -7 / 2, -7 % 3, 2 + 3 * 4") (3 -3 -1 14))
(deftest eval.int-overflow (eval-sql "SELECT 9223372036854775807 + 1") "NUMERIC_OVERFLOW")
(deftest eval.int-min (eval-sql "SELECT -9223372036854775808 % -1") (0))
(deftest eval.div-zero (eval-sql "SELECT 1 / 0") "DIVISION_BY_ZERO")
(deftest eval.null-before-div-zero (eval-sql "SELECT NULL / 0") (:null))
(deftest eval.decimal (eval-sql "SELECT 1.25 * 2.5, 2 - 0.75") (3125 125))
(deftest eval.decimal-scale-error (eval-sql "SELECT 0.000000001 * 0.0000000001") "TYPE_ERROR")
(deftest eval.three-valued (eval-sql "SELECT NULL AND FALSE, NULL OR TRUE, NOT NULL") (nil t :null))
(deftest eval.compare-mixed (eval-sql "SELECT 1 = 1.0, 2 > 1e0, DATE '2024-01-01' = TIMESTAMP '2024-01-01 00:00:00'")
  (t t t))
(deftest eval.type-error (eval-sql "SELECT 1 = '1'") "TYPE_ERROR")
(deftest eval.cast-round (eval-sql "SELECT CAST(2.345 AS DECIMAL(5,2)), CAST(-2.345 AS DECIMAL(5,2))") (235 -235))
(deftest eval.cast-string (eval-sql "SELECT CAST(' 12 ' AS INT64), CAST('abc' AS INT64)") "CONVERSION_ERROR")
(deftest eval.cast-unknown-type (eval-sql "SELECT CAST(1 AS WIDGET)") "SEMANTIC_ERROR")
(deftest eval.aggregate-no-from (eval-sql "SELECT COUNT(*), SUM(1)") (1 1))
(deftest eval.where-no-from (eval-sql "SELECT 1 WHERE FALSE") nil)
(deftest eval.limit-negative (eval-sql "SELECT 1 LIMIT -1") "INVALID_ARGUMENT")
(deftest eval.null-type (eval-sql "SELECT -NULL, NULL + NULL, NULL + 1") (:null :null :null))
(deftest eval.int-decimal-compare-overflow (eval-sql "SELECT 9223372036854775807 > 0.5") "NUMERIC_OVERFLOW")
(deftest eval.timestamp-literal-strict (eval-sql "SELECT TIMESTAMP '2024-01-01'") "CONVERSION_ERROR")
(deftest eval.paren-min-folding (eval-sql "SELECT -(9223372036854775808)") (-9223372036854775808))
(deftest eval.trailing-junk (eval-sql "SELECT 0x10") "PARSE_ERROR")
(deftest eval.star-no-from (eval-sql "SELECT *") "SEMANTIC_ERROR")
