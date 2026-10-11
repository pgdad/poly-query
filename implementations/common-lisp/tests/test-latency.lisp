;;;; test-latency.lisp — the latency optimizations agree with the row
;;;; executor: partitioned parallel aggregation, the dictionary-code path of
;;;; key tables, radix-sorted ORDER BY and shared CTE results.

(in-package #:polyquery-tests)

(defparameter *latency-queries*
  '(;; many groups (partitioned aggregation with a low threshold)
    "SELECT id % 500, COUNT(*), SUM(amount), MIN(label), MAX(ratio) FROM g GROUP BY id % 500"
    "SELECT label, grp, COUNT(*), AVG(amount) FROM g GROUP BY label, grp"
    "SELECT COUNT(DISTINCT id % 300), SUM(DISTINCT grp) FROM g"
    "SELECT DISTINCT id % 700, flag FROM g"
    ;; dictionary-coded keys (strings), with NULLs, in grouping and joins
    "SELECT label, flag, COUNT(*) FROM g GROUP BY label, flag"
    "SELECT a.label, COUNT(*) FROM g a JOIN gr b ON a.label = b.label AND a.id = b.id GROUP BY a.label"
    ;; one-argument string functions over dictionary codes (derived codes)
    "SELECT UPPER(label), COUNT(*), MAX(LENGTH(label)) FROM g WHERE LOWER(UPPER(label)) <> 'beta' GROUP BY UPPER(label)"
    "SELECT COUNT(*), SUM(CASE WHEN TRIM(label) LIKE '%a%' THEN 1 ELSE 0 END) FROM g WHERE UPPER(label) = 'GAMMA' OR label IS NULL"
    ;; ORDER BY on every key type (radix sort with a low threshold)
    "SELECT id, label, amount FROM g ORDER BY label DESC NULLS FIRST, amount, id"
    "SELECT id, ratio, day, flag FROM g ORDER BY flag NULLS LAST, ratio DESC, day, id"
    ;; CTEs referenced more than once (shared results)
    "WITH c AS (SELECT grp, SUM(amount) AS s FROM g GROUP BY grp) SELECT COUNT(*) FROM c WHERE s > (SELECT AVG(s) FROM c)"
    "WITH c AS (SELECT grp, COUNT(*) AS n FROM g GROUP BY grp) SELECT a.grp, b.n FROM c a JOIN c b ON a.grp = b.grp WHERE a.n > 100"
    "WITH c AS (SELECT label, MAX(amount) AS m FROM g GROUP BY label), d AS (SELECT * FROM c WHERE m > 0) SELECT (SELECT COUNT(*) FROM c), (SELECT COUNT(*) FROM d), COUNT(*) FROM d"))

(deftest latency.optimized-paths-agree-with-row-mode
    (let ((polyquery::*partition-groups-threshold* 8)
          (polyquery::*radix-sort-min-rows* 16))
      (remove-if (lambda (sql)
                   (let ((reference (canonical (run-with sql (options :mode :row)))))
                     (and (listp reference)
                          (every (lambda (o) (equal (canonical (run-with sql o)) reference))
                                 (list (options :mode :vectorized)
                                       (options :mode :vectorized :threads 4)
                                       (options :mode :vectorized :threads 7))))))
                 *latency-queries*))
  nil)

(deftest latency.sorted-output-order
    ;; ORDER BY results are compared in order (the radix sort is stable).
    (let ((polyquery::*radix-sort-min-rows* 16)
          (sql "SELECT id, label FROM g ORDER BY label, grp DESC"))
      (equal (run-with sql (options :mode :row))
             (run-with sql (options :mode :vectorized :threads 4))))
  t)

(deftest latency.cte-shared-once
    ;; Both references of the CTE read one shared result.
    (progn
      (unless *phase5-session* (setf *phase5-session* (phase5-session)))
      (let* ((sql "WITH c AS (SELECT grp, COUNT(*) AS n FROM g GROUP BY grp) SELECT COUNT(*) FROM c WHERE n > (SELECT AVG(n) FROM c)")
             (plan (polyquery::plan-statement *phase5-session* (parse-sql sql)
                                              (options :mode :vectorized)))
             (table (polyquery::make-shared-results-table (polyquery::physical-query-root plan))))
        (and table (loop for v being the hash-values of table thereis (> v 1)) t)))
  t)

(deftest latency.parallel-top-n-keeps-tie-order
    ;; Many ties on grp: the parallel top-N returns the serial rows, in order.
    (loop for sql in '("SELECT id, grp FROM g ORDER BY grp LIMIT 50 OFFSET 5"
                       "SELECT id, label FROM g WHERE amount > 100 ORDER BY label DESC LIMIT 300")
          always (equal (run-with sql (options :mode :row))
                        (run-with sql (options :mode :vectorized :threads 4))))
  t)
