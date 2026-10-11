;;;; test-union.lisp — UNION ALL (change request CR-1, spec/changes/union-all.md):
;;;; parsing, typing, ORDER BY/LIMIT over the compound, nesting, EXPLAIN,
;;;; column pruning and agreement of all execution options.

(in-package #:polyquery-tests)

;;; Parser

(deftest union.parse-branches
    (let ((body (polyquery::ast-query-body (parse-sql "SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3"))))
      (length (polyquery::ast-union-all-branches body)))
  3)

(deftest union.parse-single-branch-is-select
    (polyquery::ast-select-p (polyquery::ast-query-body (parse-sql "SELECT 1")))
  t)

(deftest union.parse-distinct (code-of (parse-sql "SELECT 1 UNION DISTINCT SELECT 2")) "UNSUPPORTED")
(deftest union.parse-branch-order-by
    (code-of (parse-sql "SELECT 1 ORDER BY 1 UNION ALL SELECT 2")) "PARSE_ERROR")
(deftest union.parse-branch-limit
    (code-of (parse-sql "SELECT 1 LIMIT 1 UNION ALL SELECT 2")) "PARSE_ERROR")
(deftest union.parse-parenthesized-branch
    (code-of (parse-sql "SELECT 1 UNION ALL (SELECT 2)")) "PARSE_ERROR")
(deftest union.parse-parenthesized-first
    (code-of (parse-sql "(SELECT 1) UNION ALL SELECT 2")) "PARSE_ERROR")
(deftest union.parse-nested
    (code-of (parse-sql "WITH c AS (SELECT 1 AS a UNION ALL SELECT 2)
                         SELECT * FROM (SELECT a FROM c UNION ALL SELECT 3) d
                         WHERE a IN (SELECT 1 UNION ALL SELECT 2)
                           AND EXISTS (SELECT 1 UNION ALL SELECT 2)
                           AND a < (SELECT 5 UNION ALL SELECT 6 LIMIT 1)
                         ORDER BY 1"))
  :no-error)

;;; Semantics

(defun result-types (sql)
  (handler-case
      (mapcar (lambda (c) (polyquery::type-name-string (polyquery::column-def-type c)))
              (polyquery::query-result-columns (execute-sql (fixture-session) sql)))
    (pq-error (e) (pq-error-code e))))

(deftest union.keeps-duplicates
    (sorted-rows "SELECT g FROM t WHERE id = 1 UNION ALL SELECT g FROM t WHERE id <= 2")
  (("a") ("a") ("a")))

(deftest union.names-from-first-branch
    (mapcar #'polyquery::column-def-name
            (polyquery::query-result-columns
             (execute-sql (fixture-session) "SELECT id AS x, w FROM u UNION ALL SELECT v, s AS y FROM t")))
  ("x" "w"))

(deftest union.common-types
    (list (result-types "SELECT 1 AS a UNION ALL SELECT CAST(2.5 AS FLOAT64)")
          (result-types "SELECT 1 AS a UNION ALL SELECT 2.5")
          (result-types "SELECT 1 AS a UNION ALL SELECT CAST(2 AS DECIMAL(5,3))")
          (result-types "SELECT CAST(1 AS DECIMAL(4,1)) AS a UNION ALL SELECT CAST(2 AS DECIMAL(5,3))")
          (result-types "SELECT NULL AS a UNION ALL SELECT DATE '2024-01-01'")
          (result-types "SELECT NULL AS a UNION ALL SELECT NULL"))
  (("FLOAT64") ("DECIMAL(18,1)") ("DECIMAL(18,3)") ("DECIMAL(18,3)") ("DATE") ("STRING")))

(deftest union.values-converted
    (list (query-rows "SELECT 1 AS a UNION ALL SELECT CAST(2.5 AS FLOAT64) ORDER BY a")
          ;; DECIMAL(18,1) values are held as scaled integers.
          (query-rows "SELECT 2.5 AS a UNION ALL SELECT 1 ORDER BY a"))
  (((1.0d0) (2.5d0)) ((10) (25))))

(deftest union.decimal-overflow
    (query-rows "SELECT 9223372036854775807 AS a UNION ALL SELECT CAST(1 AS DECIMAL(5,2))")
  "NUMERIC_OVERFLOW")

(deftest union.errors
    (list (query-rows "SELECT id, g FROM t UNION ALL SELECT id FROM t")
          (query-rows "SELECT g FROM t UNION ALL SELECT id FROM t")
          (query-rows "SELECT TRUE UNION ALL SELECT DATE '2024-01-01'")
          (query-rows "SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY id + 1")
          (query-rows "SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY t.id")
          (query-rows "SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY w")
          (query-rows "SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY 2")
          (query-rows "SELECT 1 AS a, 2 AS a UNION ALL SELECT 3, 4 ORDER BY a"))
  ("SEMANTIC_ERROR" "TYPE_ERROR" "TYPE_ERROR" "SEMANTIC_ERROR" "SEMANTIC_ERROR"
   "SEMANTIC_ERROR" "SEMANTIC_ERROR" "SEMANTIC_ERROR"))

(deftest union.order-limit-whole-result
    (query-rows "SELECT id, g FROM t UNION ALL SELECT id, w FROM u ORDER BY 1 DESC, g LIMIT 3 OFFSET 1")
  ((4 :null) (3 "b") (3 "drei")))

(deftest union.aggregates-in-branches
    (query-rows "SELECT 't' AS src, COUNT(*) AS n FROM t UNION ALL SELECT 'u', COUNT(*) FROM u
                 UNION ALL SELECT g, SUM(v) FROM t WHERE g IS NOT NULL GROUP BY g ORDER BY src")
  (("a" 30) ("b" 30) ("t" 4) ("u" 4)))

(deftest union.distinct-branch
    (sorted-rows "SELECT DISTINCT id FROM u UNION ALL SELECT DISTINCT id FROM u WHERE id > 1")
  ((1) (3) (3) (5) (5)))

(deftest union.in-cte-derived-and-subqueries
    (list (query-rows "WITH c AS (SELECT id FROM t UNION ALL SELECT id FROM u)
                       SELECT COUNT(*), COUNT(DISTINCT id) FROM c")
          (query-rows "SELECT SUM(x) FROM (SELECT v AS x FROM t UNION ALL SELECT id FROM u) d")
          (query-rows "SELECT id FROM t WHERE id IN (SELECT id FROM u UNION ALL SELECT 2) ORDER BY id")
          (query-rows "SELECT EXISTS (SELECT 1 FROM t WHERE id < 0 UNION ALL SELECT 1 FROM u WHERE id = 5)")
          (query-rows "SELECT (SELECT 1 UNION ALL SELECT 2)"))
  (((8 5)) ((112)) ((1) (2) (3)) ((t)) "SUBQUERY_CARDINALITY"))

(deftest union.correlated-branches
    (query-rows "SELECT t.id, (SELECT COUNT(*) FROM (SELECT id FROM u WHERE u.id = t.id
                                                     UNION ALL SELECT t.id) x) FROM t ORDER BY t.id")
  ((1 2) (2 1) (3 3) (4 1)))

;;; Planning

(deftest union.explain
    (plan-ops "SELECT id FROM t UNION ALL SELECT id FROM u")
  ("UnionAll" "Project" "TableScan" "Project" "TableScan"))

(deftest union.explain-order-limit
    (first (plan-ops "SELECT id FROM t UNION ALL SELECT id FROM u ORDER BY id LIMIT 2"))
  "TopN")

(deftest union.pruning-per-branch
    (list (scan-columns "SELECT COUNT(*) FROM (SELECT * FROM t UNION ALL SELECT id, w, id, w FROM u) d" "t")
          (scan-columns "SELECT s FROM (SELECT id, s FROM t UNION ALL SELECT id, w FROM u) d" "u"))
  (nil ("w")))

;;; Execution options

(defparameter *union-queries*
  '("SELECT id, label FROM g WHERE grp = 3 UNION ALL SELECT k, name FROM small UNION ALL SELECT id, label FROM gr WHERE amount > 900"
    "SELECT grp, COUNT(*), SUM(x) FROM (SELECT grp, amount AS x FROM g UNION ALL SELECT grp, id FROM gr) d GROUP BY grp"
    "SELECT DISTINCT x FROM (SELECT label AS x FROM g UNION ALL SELECT name FROM small) d"
    "SELECT a.id, d.n FROM g a JOIN (SELECT k AS id, name AS n FROM small UNION ALL SELECT id, label FROM gr WHERE id < 50) d ON a.id = d.id"
    "SELECT id, amount FROM g WHERE id < 100 UNION ALL SELECT id, ratio FROM gr WHERE id > 2900 ORDER BY 2 DESC NULLS LAST, 1 LIMIT 10 OFFSET 3"
    "SELECT id FROM g WHERE grp IN (SELECT k FROM small UNION ALL SELECT 7) UNION ALL SELECT 100 / (grp - grp) FROM gr WHERE id = 0"))

(deftest union.modes-agree
    (remove-if #'same-in-all-modes *union-queries*)
  nil)
