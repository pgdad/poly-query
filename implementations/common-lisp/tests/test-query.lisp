;;;; test-query.lisp — Phase 2 analysis, planning and execution: joins,
;;;; grouping, subqueries, CTEs, functions and EXPLAIN plans.

(in-package #:polyquery-tests)

(defparameter *fixture-tables*
  '(("t" "id,g,v,s
1,a,10,x
2,a,20,y
3,b,30,
4,,40,z
")
    ("u" "id,w
1,one
3,three
3,drei
5,five
")))

(defun fixture-session ()
  (let ((session (make-session (make-engine-config :data-dir "/nonexistent/"))))
    (loop for (name data) in *fixture-tables*
          do (handle-request session (jobj "op" "load" "table" name "format" "csv" "data" data)))
    session))

(defun query-rows (sql)
  "Rows of SQL over the fixture tables as lists, or the error code."
  (handler-case
      (mapcar (lambda (row) (coerce row 'list))
              (polyquery::query-result-rows (execute-sql (fixture-session) sql)))
    (pq-error (e) (pq-error-code e))))

(defun sorted-rows (sql)
  (let ((rows (query-rows sql)))
    (if (listp rows)
        (sort rows #'string< :key #'prin1-to-string)
        rows)))

(defun plan-ops (sql)
  "All operator names of the EXPLAIN plan of SQL, depth first."
  (let ((ops '()))
    (labels ((walk (node)
               (push (polyquery::json-get node "op") ops)
               (mapc #'walk (polyquery::json-get node "children"))))
      (walk (polyquery::explain-sql (fixture-session) sql)))
    (nreverse ops)))

(defun scan-columns (sql table)
  "Columns read by the TableScan of TABLE in the plan of SQL."
  (labels ((walk (node)
             (if (and (equal (polyquery::json-get node "op") "TableScan")
                      (equal (polyquery::json-get node "table") table))
                 (polyquery::json-get node "columns")
                 (some #'walk (polyquery::json-get node "children")))))
    (walk (polyquery::explain-sql (fixture-session) sql))))

;;; Joins

(deftest join.inner (sorted-rows "SELECT t.id, u.w FROM t JOIN u ON t.id = u.id")
  ((1 "one") (3 "drei") (3 "three")))
(deftest join.left (sorted-rows "SELECT t.id, u.w FROM t LEFT JOIN u ON t.id = u.id")
  ((1 "one") (2 :null) (3 "drei") (3 "three") (4 :null)))
(deftest join.left-on-filter (sorted-rows "SELECT t.id, u.w FROM t LEFT JOIN u ON t.id = u.id AND u.w = 'one'")
  ((1 "one") (2 :null) (3 :null) (4 :null)))
(deftest join.cross-count (query-rows "SELECT COUNT(*) FROM t, u") ((16)))
(deftest join.ambiguous (query-rows "SELECT id FROM t JOIN u ON t.id = u.id") "SEMANTIC_ERROR")
(deftest join.duplicate-range-variable (query-rows "SELECT 1 FROM t, t") "SEMANTIC_ERROR")
(deftest join.hash-chosen (plan-ops "SELECT 1 FROM t, u WHERE t.id = u.id")
  ("Project" "HashJoin" "TableScan" "TableScan"))
(deftest join.nested-loop-for-non-equi (plan-ops "SELECT 1 FROM t JOIN u ON t.id < u.id")
  ("Project" "NestedLoopJoin" "TableScan" "TableScan"))

;;; Optimizer: pushdown and pruning

(deftest plan.pushdown-below-join
    (plan-ops "SELECT t.id FROM t JOIN u ON t.id = u.id WHERE t.v > 10 AND u.w = 'one'")
  ("Project" "HashJoin" "Filter" "TableScan" "Filter" "TableScan"))
(deftest plan.no-pushdown-into-left-join-null-side
    (plan-ops "SELECT t.id FROM t LEFT JOIN u ON t.id = u.id WHERE u.w IS NULL")
  ("Project" "Filter" "HashJoin" "TableScan" "TableScan"))
(deftest plan.column-pruning (scan-columns "SELECT g FROM t WHERE v > 1" "t") ("g" "v"))
(deftest plan.count-star-reads-nothing (scan-columns "SELECT COUNT(*) FROM t" "t") ())

;;; Grouping and DISTINCT

(deftest group.basic (sorted-rows "SELECT g, COUNT(*), SUM(v) FROM t GROUP BY g")
  (("a" 2 30) ("b" 1 30) (:null 1 40)))
(deftest group.having (query-rows "SELECT g FROM t GROUP BY g HAVING COUNT(*) > 1") (("a")))
(deftest group.alias-and-ordinal (sorted-rows "SELECT g AS k, COUNT(*) FROM t GROUP BY k")
  (("a" 2) ("b" 1) (:null 1)))
(deftest group.ordinal (query-rows "SELECT v / 20, COUNT(*) FROM t GROUP BY 1 ORDER BY 1")
  ((0 1) (1 2) (2 1)))
(deftest group.ungrouped-column (query-rows "SELECT s FROM t GROUP BY g") "SEMANTIC_ERROR")
(deftest group.empty-input (query-rows "SELECT g, COUNT(*) FROM t WHERE id > 9 GROUP BY g") nil)
(deftest group.no-group-by-empty-input (query-rows "SELECT COUNT(*), SUM(v) FROM t WHERE id > 9")
  ((0 :null)))
(deftest group.nested-aggregate (query-rows "SELECT SUM(COUNT(*)) FROM t") "SEMANTIC_ERROR")
(deftest distinct.rows (query-rows "SELECT DISTINCT g FROM t ORDER BY g") ((:null) ("a") ("b")))
(deftest distinct.order-by-not-selected (query-rows "SELECT DISTINCT g FROM t ORDER BY v")
  "SEMANTIC_ERROR")
(deftest distinct.count (query-rows "SELECT COUNT(DISTINCT g), COUNT(g) FROM t") ((2 3)))

;;; Subqueries and CTEs

(deftest subquery.scalar (query-rows "SELECT (SELECT MAX(v) FROM t)") ((40)))
(deftest subquery.scalar-empty (query-rows "SELECT (SELECT v FROM t WHERE id > 9)") ((:null)))
(deftest subquery.cardinality (query-rows "SELECT (SELECT v FROM t)") "SUBQUERY_CARDINALITY")
(deftest subquery.in (query-rows "SELECT id FROM t WHERE id IN (SELECT id FROM u) ORDER BY id")
  ((1) (3)))
(deftest subquery.not-in-with-null (query-rows "SELECT 2 NOT IN (SELECT CASE WHEN id = 1 THEN NULL ELSE id END FROM u)")
  ((:null)))
(deftest subquery.in-empty (query-rows "SELECT NULL IN (SELECT id FROM u WHERE id < 0)") ((nil)))
(deftest subquery.exists (query-rows "SELECT EXISTS (SELECT 1 FROM u WHERE id = 5)") ((t)))
(deftest subquery.correlated
    (query-rows "SELECT id, (SELECT COUNT(*) FROM u WHERE u.id = t.id) FROM t ORDER BY id")
  ((1 1) (2 0) (3 2) (4 0)))
(deftest subquery.correlated-exists
    (query-rows "SELECT id FROM t WHERE NOT EXISTS (SELECT 1 FROM u WHERE u.id = t.id) ORDER BY id")
  ((2) (4)))
(deftest subquery.correlated-in-having
    (query-rows "SELECT g FROM t x GROUP BY g HAVING COUNT(*) = (SELECT COUNT(*) FROM t y WHERE y.g = x.g)
                 ORDER BY g")
  (("a") ("b")))
(deftest subquery.derived (query-rows "SELECT d.n FROM (SELECT COUNT(*) AS n FROM t) d") ((4)))
(deftest subquery.derived-alias-required (query-rows "SELECT * FROM (SELECT 1)") "PARSE_ERROR")
(deftest cte.chain (query-rows "WITH a AS (SELECT 1 AS x), b AS (SELECT x + 1 AS y FROM a) SELECT y FROM b")
  ((2)))
(deftest cte.shadows-table (query-rows "WITH t AS (SELECT 7 AS id) SELECT id FROM t") ((7)))
(deftest cte.self-reference-is-catalog (query-rows "WITH t AS (SELECT COUNT(*) AS n FROM t) SELECT n FROM t")
  ((4)))
(deftest cte.column-count-mismatch (query-rows "WITH c(a, b) AS (SELECT 1) SELECT * FROM c")
  "SEMANTIC_ERROR")

;;; Expressions and functions

(deftest expr.case (query-rows "SELECT CASE WHEN v > 25 THEN 'hi' ELSE 'lo' END FROM t ORDER BY id")
  (("lo") ("lo") ("hi") ("hi")))
(deftest expr.like (query-rows "SELECT 'abc' LIKE 'a%', 'abc' LIKE '_b', 'a' LIKE NULL") ((t nil :null)))
(deftest expr.between (query-rows "SELECT id FROM t WHERE v BETWEEN 15 AND 30 ORDER BY id") ((2) (3)))
(deftest expr.in-list (query-rows "SELECT 1 IN (2, NULL), 1 IN (1.0, 3), 1 NOT IN (2, 3)") ((:null t t)))
(deftest fn.round (query-rows "SELECT ROUND(2.345, 2), ROUND(15, -1), ROUND(-2.5)") ((235 20 -3)))
(deftest fn.round-non-constant (query-rows "SELECT ROUND(1.5, id) FROM t") "SEMANTIC_ERROR")
(deftest fn.substr (query-rows "SELECT SUBSTR('hello', 0, 2), SUBSTR('hello', 4)") (("h" "lo")))
(deftest fn.concat (query-rows "SELECT CONCAT('a', NULL, 1, TRUE)") (("a1true")))
(deftest fn.coalesce (query-rows "SELECT COALESCE(NULL, 2, 3), COALESCE(1, 2.5)") ((2 10)))
(deftest fn.coalesce-false (query-rows "SELECT COALESCE(NULL, FALSE, TRUE), COALESCE(NULL)") ((nil :null)))
(deftest fn.date-diff (query-rows "SELECT DATE_DIFF('day', DATE '2024-01-01', DATE '2024-03-01')") ((60)))
(deftest fn.power-errors
    (list (query-rows "SELECT POWER(0, -1)") (query-rows "SELECT POWER(-8, 0.5)"))
  ("DIVISION_BY_ZERO" "INVALID_ARGUMENT"))
(deftest fn.unknown (query-rows "SELECT NOPE(1)") "SEMANTIC_ERROR")
(deftest fn.like-matcher
    (mapcar (lambda (args) (apply #'polyquery::like-match-p args))
            '(("abc" "a%c") ("abc" "%%%") ("" "_") ("aXbXc" "a%b%c") ("abcb" "%b")))
  (t t nil t t))

;;; EXPLAIN

(deftest explain.statement (length (query-rows "EXPLAIN SELECT * FROM t")) 1)
(deftest explain.semantic-error (query-rows "EXPLAIN SELECT nope FROM t") "SEMANTIC_ERROR")
