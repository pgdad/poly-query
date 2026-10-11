;;;; test-plan.lisp — query planning: the logical plan builder, every rule of
;;;; the logical optimizer on its own, the optimizer driver (incl.
;;;; `optimize: false`) and the physical planner.
;;;;
;;;; Logical plans are compared in their printed form (FORMAT-LOGICAL-PLAN).

(in-package #:polyquery-tests)

(defparameter *plan-session* nil)

(defun plan-session ()
  (or *plan-session*
      (let ((session (make-session (make-engine-config :data-dir "/nonexistent/"))))
        (flet ((load-csv (name text)
                 (handle-request session (jobj "op" "load" "table" name "format" "csv" "data" text))))
          (load-csv "t" (format nil "a,b,c~%1,x,1.5~%2,y,2.5~%3,z,~%"))
          (load-csv "u" (format nil "x,y~%1,p~%2,q~%"))
          (load-csv "v" (format nil "k~%1~%2~%3~%4~%5~%6~%")))
        (execute-sql session "CREATE INDEX v_k ON v (k) USING HASH")
        (setf *plan-session* session))))

(defun bound (sql)
  (polyquery::bind-statement (parse-sql sql) (polyquery::session-catalog (plan-session))))

(defmacro with-planning (() &body body)
  "Run BODY as the engine plans: in a query context, with the catalog's indexes."
  `(let ((polyquery::*query-context* (polyquery::make-context-for (plan-session) nil))
         (polyquery::*planning-catalog* (polyquery::session-catalog (plan-session))))
     ,@body))

(defun plan-lines (plan)
  "The printed logical PLAN as a list of lines."
  (with-input-from-string (in (polyquery::format-logical-plan plan))
    (loop for line = (read-line in nil) while line collect line)))

(defun raw-plan (sql)
  "The logical plan of SQL as built from the query, before column pruning."
  (with-planning () (polyquery::plan-query (bound sql))))

(defun built-plan (sql)
  "The logical plan of SQL as the planner starts from (pruned scans,
subquery plans)."
  (with-planning () (polyquery::build-logical-plan (bound sql))))

(defun after-rules (sql &rest rules)
  "Printed plan of SQL after applying RULES (names) in order to its built plan."
  (with-planning ()
    (plan-lines (reduce (lambda (plan rule) (polyquery::apply-optimizer-rule rule plan))
                        rules :initial-value (polyquery::build-logical-plan (bound sql))))))

;;; ------------------------------------------------------------------
;;; Logical plan and builder

(deftest plan.builder-select-shape
    (plan-lines (raw-plan "SELECT b FROM t WHERE a > 1 ORDER BY c DESC LIMIT 3"))
  ("Project [b]"
   "  Limit 3 offset -"
   "    Sort [c DESC NULLS LAST]"
   "      Project [b, c]"
   "        Filter (a > 1)"
   "          Scan t AS t [a, b, c]"))

(deftest plan.builder-aggregate-shape
    (plan-lines (raw-plan "SELECT b, COUNT(*) FROM t GROUP BY b HAVING COUNT(*) > 1"))
  ("Project [b, COUNT(*)]"
   "  Filter (COUNT(*) > 1)"
   "    Aggregate keys [b] aggregates [COUNT(*)]"
   "      Scan t AS t [a, b, c]"))

(deftest plan.builder-joins
    (plan-lines (raw-plan "SELECT * FROM t LEFT JOIN u ON t.a = u.x, v"))
  ("Project [a, b, c, x, y, k]"
   "  Join CROSS"
   "    Join LEFT ON (a = x)"
   "      Scan t AS t [a, b, c]"
   "      Scan u AS u [x, y]"
   "    Scan v AS v [k]"))

(deftest plan.builder-derived-table-and-cte
    (plan-lines (raw-plan "WITH w AS (SELECT a FROM t) SELECT d.y FROM w, (SELECT DISTINCT y FROM u) d"))
  ("Project [y]"
   "  Join CROSS"
   "    SubqueryAlias w (CTE) [a]"
   "      Project [a]"
   "        Scan t AS t [a, b, c]"
   "    SubqueryAlias d [y]"
   "      Distinct"
   "        Project [y]"
   "          Scan u AS u [x, y]"))

(deftest plan.builder-union-all
    (plan-lines (raw-plan "SELECT a FROM t UNION ALL SELECT x FROM u"))
  ("UnionAll [a]"
   "  Project [a]"
   "    Scan t AS t [a, b, c]"
   "  Project [x]"
   "    Scan u AS u [x, y]"))

(deftest plan.builder-prunes-scans
    (plan-lines (built-plan "SELECT b FROM t WHERE a > 1"))
  ("Project [b]"
   "  Filter (a > 1)"
   "    Scan t AS t [a, b]"))

(deftest plan.builder-subquery-plans
    (plan-lines (built-plan "SELECT a FROM t WHERE a IN (SELECT x FROM u WHERE y = 'p')"))
  ("Project [a]"
   "  Filter a IN (subquery)"
   "    Subquery in"
   "      Project [x]"
   "        Filter (y = 'p')"
   "          Scan u AS u [x, y]"
   "    Scan t AS t [a]"))

(deftest plan.lnode-expressions
    (with-planning ()
      (mapcar #'polyquery::bexpr-describe
              (polyquery::lnode-expressions
               (polyquery::lnode-child (built-plan "SELECT a FROM t WHERE b <> 'x'")))))
  ("(b <> 'x')"))

;;; ------------------------------------------------------------------
;;; Optimizer rules, each on its own

(deftest plan.rule-constant-folding
    (after-rules "SELECT a + (1 + 2), 1 / 0 FROM t WHERE b = 'x' AND 2 > 1" :constant-folding)
  ("Project [(a + 3), (1 / 0)]"
   "  Filter ((b = 'x') AND true)"
   "    Scan t AS t [a, b]"))

(deftest plan.rule-constant-folding-only-folds
    ;; Folding alone leaves boolean structure (and NOT) alone.
    (after-rules "SELECT a FROM t WHERE NOT (a < 2 + 1)" :constant-folding)
  ("Project [a]"
   "  Filter NOT (a < 3)"
   "    Scan t AS t [a]"))

(deftest plan.rule-predicate-simplification
    (list (after-rules "SELECT a FROM t WHERE NOT (a < 2) AND (b = 'x' OR b = 'x')"
                       :predicate-simplification)
          (after-rules "SELECT a FROM t WHERE 1 = 1" :constant-folding :predicate-simplification)
          ;; FALSE does not hide an operand evaluated before it that may fail.
          (after-rules "SELECT a FROM t WHERE 10 / a > 1 AND 1 = 2"
                       :constant-folding :predicate-simplification)
          (after-rules "SELECT a FROM t WHERE a > 1 AND 1 = 2"
                       :constant-folding :predicate-simplification))
  (("Project [a]"
    "  Filter ((a >= 2) AND (b = 'x'))"
    "    Scan t AS t [a, b]")
   ("Project [a]"
    "  Scan t AS t [a]")
   ("Project [a]"
    "  Filter (((10 / a) > 1) AND false)"
    "    Scan t AS t [a]")
   ("Project [a]"
    "  Filter false"
    "    Scan t AS t [a]")))

(deftest plan.rule-predicate-pushdown-into-joins
    (after-rules "SELECT t.b, u.y FROM t, u WHERE t.a = u.x AND t.c > 1.0 AND u.y <> 'p'"
                 :predicate-pushdown)
  ("Project [b, y]"
   "  Join INNER ON (a = x)"
   "    Filter (c > 1.0)"
   "      Scan t AS t [a, b, c]"
   "    Filter (y <> 'p')"
   "      Scan u AS u [x, y]"))

(deftest plan.rule-predicate-pushdown-left-join
    ;; Never into the NULL-supplying side from above; the preserved side and
    ;; the ON condition's own right-side conjuncts are pushed.
    (after-rules "SELECT t.b FROM t LEFT JOIN u ON t.a = u.x AND u.y = 'p' WHERE u.y IS NULL AND t.a > 1"
                 :predicate-pushdown)
  ("Project [b]"
   "  Filter y IS NULL"
   "    Join LEFT ON (a = x)"
   "      Filter (a > 1)"
   "        Scan t AS t [a, b]"
   "      Filter (y = 'p')"
   "        Scan u AS u [x, y]"))

(deftest plan.rule-predicate-pushdown-below-projection
    (after-rules "SELECT n FROM (SELECT b AS n, a FROM t WHERE c > 0.0) d WHERE a = 1 AND n <> 'z'"
                 :predicate-pushdown)
  ("Project [n]"
   "  SubqueryAlias d [n, a]"
   "    Project [b, a]"
   "      Filter (((c > 0.0) AND (a = 1)) AND (b <> 'z'))"
   "        Scan t AS t [a, b, c]"))

(deftest plan.rule-predicate-pushdown-keeps-failing-projection
    ;; Filtering below the Project would skip evaluating 10 / (a - 2) for
    ;; rows that the unoptimized plan evaluates (and fails on).
    (after-rules "SELECT q FROM (SELECT a, 10 / (a - 2) AS q FROM t) d WHERE a = 1"
                 :predicate-pushdown)
  ("Project [q]"
   "  SubqueryAlias d [a, q]"
   "    Filter (a = 1)"
   "      Project [a, (10 / (a - 2))]"
   "        Scan t AS t [a]"))

(deftest plan.rule-predicate-pushdown-stops-at-aggregate-and-limit
    (after-rules "SELECT * FROM (SELECT a FROM t ORDER BY a LIMIT 2) d WHERE a > 1"
                 :predicate-pushdown)
  ("Project [a]"
   "  SubqueryAlias d [a]"
   "    Filter (a > 1)"
   "      Limit 2 offset -"
   "        Sort [a ASC NULLS FIRST]"
   "          Project [a]"
   "            Scan t AS t [a]"))

(deftest plan.rule-join-reordering
    ;; t, v, u has a cross product (t-v); the smallest input (u) starts and
    ;; connected inputs follow. A Project restores the written column order.
    (after-rules "SELECT 1 FROM t, v, u WHERE t.a = u.x AND u.x = v.k"
                 :predicate-pushdown :join-reordering)
  ("Project [1]"
   "  Project [a, k, x]"
   "    Join INNER ON (x = k)"
   "      Join INNER ON (a = x)"
   "        Scan u AS u [x]"
   "        Scan t AS t [a]"
   "      Scan v AS v [k]"))

(deftest plan.rule-join-reordering-keeps-connected-order
    (after-rules "SELECT 1 FROM t JOIN u ON t.a = u.x JOIN v ON v.k = u.x" :join-reordering)
  ("Project [1]"
   "  Join INNER ON (k = x)"
   "    Join INNER ON (a = x)"
   "      Scan t AS t [a]"
   "      Scan u AS u [x]"
   "    Scan v AS v [k]"))

(deftest plan.rule-column-pruning
    (with-planning ()
      (plan-lines (polyquery::apply-optimizer-rule
                   :column-pruning
                   (polyquery::plan-query (bound "SELECT d.p FROM (SELECT b AS p, c + 1 AS q FROM t) d, u")))))
  ("Project [p]"
   "  Join CROSS"
   "    SubqueryAlias d [p]"
   "      Project [b]"
   "        Scan t AS t [b]"
   "    Scan u AS u []"))

(deftest plan.rule-column-pruning-union-branches
    (with-planning ()
      (plan-lines (polyquery::apply-optimizer-rule
                   :column-pruning
                   (polyquery::plan-query
                    (bound "SELECT n FROM (SELECT a AS n, b FROM t UNION ALL SELECT x, y FROM u) z")))))
  ("Project [n]"
   "  SubqueryAlias z [n]"
   "    UnionAll [n]"
   "      Project [a]"
   "        Scan t AS t [a]"
   "      Project [x]"
   "        Scan u AS u [x]"))

;;; ------------------------------------------------------------------
;;; Optimizer driver

(deftest plan.optimizer-rule-order
    (mapcar #'polyquery::optimizer-rule-name polyquery::*optimizer-rules*)
  (:constant-folding :predicate-simplification :predicate-pushdown :join-reordering :column-pruning))

(deftest plan.optimizer-disabled-applies-no-rule
    (with-planning ()
      (let ((plan (polyquery::build-logical-plan
                   (bound "SELECT a FROM t, u WHERE a = x AND 1 + 1 = 2 AND a IN (SELECT k FROM v WHERE 2 > 1)"))))
        (list (eq plan (polyquery::optimize-logical-plan plan :enabled nil))
              (plan-lines plan))))
  (t ("Project [a]"
      "  Filter (((a = x) AND ((1 + 1) = 2)) AND a IN (subquery))"
      "    Subquery in"
      "      Project [k]"
      "        Filter (2 > 1)"
      "          Scan v AS v [k]"
      "    Join CROSS"
      "      Scan t AS t [a]"
      "      Scan u AS u [x]")))

(deftest plan.optimizer-all-rules-and-subqueries
    (with-planning ()
      (plan-lines (polyquery::optimize-logical-plan
                   (polyquery::build-logical-plan
                    (bound "SELECT a FROM t, u WHERE a = x AND 1 + 1 = 2 AND a IN (SELECT k FROM v WHERE 2 > 1)")))))
  ("Project [a]"
   "  Join INNER ON (a = x)"
   "    Filter a IN (subquery)"
   "      Subquery in"
   "        Project [k]"
   "          Scan v AS v [k]"
   "      Scan t AS t [a]"
   "    Scan u AS u [x]"))

(deftest plan.optimizer-selected-rules
    (with-planning ()
      (plan-lines (polyquery::optimize-logical-plan
                   (polyquery::build-logical-plan (bound "SELECT a FROM t WHERE a > 1 + 1"))
                   :rules (list (polyquery::find-optimizer-rule :constant-folding)))))
  ("Project [a]"
   "  Filter (a > 2)"
   "    Scan t AS t [a]"))

;;; ------------------------------------------------------------------
;;; Physical planner

(defun physical-root (sql &rest option-args)
  (with-planning ()
    (polyquery::physical-query-root
     (polyquery::plan-statement (plan-session) (parse-sql sql)
                                (apply #'polyquery::make-exec-options option-args)))))

(defun physical-ops (node)
  "Operator types of the physical plan NODE, pre-order."
  (cons (type-of node) (mapcan #'physical-ops (polyquery::pnode-children node))))

(deftest plan.physical-access-paths
    (list (physical-ops (physical-root "SELECT k FROM v WHERE k = 3"))
          (physical-ops (physical-root "SELECT k FROM v WHERE k = 3" :use-indexes nil))
          (physical-ops (physical-root "SELECT k FROM v WHERE k > 3 AND k < 5")))
  ((polyquery::pp-project polyquery::pp-index-scan)
   (polyquery::pp-project polyquery::pp-filter polyquery::pp-table-scan)
   (polyquery::pp-project polyquery::pp-filter polyquery::pp-table-scan)))

(deftest plan.physical-join-algorithms
    (loop for join in '(:auto :hash :merge :nested-loop)
          collect (find-if (lambda (op) (search "JOIN" (symbol-name op)))
                           (physical-ops (physical-root "SELECT 1 FROM t JOIN u ON t.a = u.x"
                                                        :join join))))
  (polyquery::pp-hash-join polyquery::pp-hash-join polyquery::pp-merge-join
   polyquery::pp-nested-loop-join))

(deftest plan.physical-join-build-side
    ;; Inner hash joins build on the smaller input; LEFT joins on the right.
    (list (polyquery::pp-hash-join-build
           (polyquery::pnode-child (physical-root "SELECT 1 FROM u JOIN v ON v.k = u.x")))
          (polyquery::pp-hash-join-build
           (polyquery::pnode-child (physical-root "SELECT 1 FROM u LEFT JOIN v ON v.k = u.x"))))
  (:left :right))

(deftest plan.physical-subquery-alias-is-transparent
    (physical-ops (physical-root "SELECT * FROM (SELECT b FROM t) d"))
  (polyquery::pp-project polyquery::pp-project polyquery::pp-table-scan))

(deftest plan.physical-top-n-and-subquery-plans
    (let ((root (physical-root "SELECT a FROM t WHERE a IN (SELECT x FROM u) ORDER BY a LIMIT 2")))
      (list (physical-ops root)
            (physical-ops (polyquery::subquery-plan
                           (first (polyquery::expression-subqueries
                                   (polyquery::node-expressions
                                    (polyquery::pnode-child (polyquery::pnode-child root)))))))))
  ((polyquery::pp-top-n polyquery::pp-project polyquery::pp-filter polyquery::pp-table-scan)
   (polyquery::pp-project polyquery::pp-table-scan)))

(defun settings-of (&rest option-args)
  (let ((s (polyquery::choose-execution-settings (apply #'polyquery::make-exec-options option-args))))
    (list (polyquery::execution-settings-mode s)
          (polyquery::execution-settings-threads s)
          (polyquery::execution-settings-native s))))

(deftest plan.physical-execution-settings
    (let ((polyquery::*native-library* nil))
      (list (settings-of)
            (settings-of :mode :row :threads 4)
            (settings-of :mode :vectorized :threads 3 :native t)))
  ((:vectorized 1 nil) (:row 4 nil) (:vectorized 3 nil)))

(deftest plan.physical-native-only-when-vectorized
    (let ((polyquery::*native-library* :loaded))
      (list (settings-of :native t) (settings-of :mode :row :native t) (settings-of)))
  ((:vectorized 1 t) (:row 1 nil) (:vectorized 1 nil)))
