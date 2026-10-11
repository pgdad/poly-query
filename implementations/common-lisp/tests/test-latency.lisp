;;;; test-latency.lisp — the latency optimizations: radix sorting, partitioned
;;;; and probed parallel aggregation, parallel top-N, integer DISTINCT sets,
;;;; uncorrelated subquery kernels, INT64/DECIMAL vs FLOAT64 comparisons.
;;;; Uses the Phase 5 test session and option matrix (test-phase5.lisp).

(in-package #:polyquery-tests)

(defun same-in-all-modes-with-morsels (sql morsel-rows)
  "SAME-IN-ALL-MODES with morsels of MORSEL-ROWS rows."
  (let ((polyquery::*morsel-rows* morsel-rows))
    (flet ((run (options)
             (unless *phase5-session* (setf *phase5-session* (phase5-session)))
             (canonical
              (handler-case
                  (mapcar (lambda (row) (coerce row 'list))
                          (polyquery::query-result-rows
                           (execute-sql *phase5-session* sql :options options)))
                (pq-error (e) (pq-error-code e))))))
      (let ((reference (run (options :mode :row))))
        (every (lambda (o) (equal (run o) reference))
               (list* (options :mode :vectorized :threads 16) *option-matrix*))))))

(defparameter *latency-queries*
  '(;; many groups: partitioned aggregation (more than 32 morsels) or the
    ;; serial probe path (at most 32), DISTINCT with many groups
    "SELECT id % 1000, COUNT(*), SUM(amount), MIN(label), AVG(ratio) FROM g GROUP BY id % 1000"
    "SELECT id, grp, COUNT(*) FROM g GROUP BY id, grp HAVING COUNT(*) = 1"
    "SELECT label, id % 700, COUNT(DISTINCT grp) FROM g GROUP BY label, id % 700"
    "SELECT DISTINCT id % 1500, flag FROM g"
    "SELECT n, COUNT(*) FROM (SELECT id % 900 AS k, COUNT(*) AS n FROM g GROUP BY id % 900) d GROUP BY n"
    ;; integer DISTINCT sets, also without GROUP BY (parallel union)
    "SELECT COUNT(DISTINCT id), COUNT(DISTINCT id % 997), SUM(DISTINCT grp), AVG(DISTINCT amount) FROM g"
    "SELECT grp, COUNT(DISTINCT day), SUM(DISTINCT id % 7) FROM g GROUP BY grp"
    ;; top-N with ties, NULLs and offsets (parallel top-N)
    "SELECT id, grp FROM g ORDER BY grp LIMIT 50"
    "SELECT id, grp, label FROM g ORDER BY grp DESC NULLS FIRST, label LIMIT 40 OFFSET 30"
    "SELECT id FROM g WHERE amount > 100 ORDER BY ratio NULLS LAST LIMIT 25"
    ;; radix sort keys: INT64, DECIMAL, FLOAT64 (with -0.0 and NULLs), DATE, DESC
    "SELECT id, ratio, amount FROM g ORDER BY ratio DESC, amount, id"
    "SELECT id FROM g ORDER BY ratio * 0 NULLS FIRST, id DESC"
    "SELECT id, day FROM g ORDER BY day DESC NULLS LAST, grp NULLS FIRST, id"
    ;; uncorrelated subqueries in parallel pipelines
    "SELECT COUNT(*) FROM g WHERE amount > (SELECT AVG(amount) FROM g)"
    "SELECT id FROM g WHERE ratio < (SELECT MIN(ratio) FROM gr) + 1"
    "SELECT COUNT(*), SUM(amount) FROM g WHERE grp IN (SELECT k FROM small)"
    "SELECT COUNT(*) FROM g WHERE grp NOT IN (SELECT k FROM small WHERE k > 2)"
    "SELECT COUNT(*) FROM g WHERE amount IN (SELECT amount FROM gr WHERE id < 50)"
    "SELECT COUNT(*) FROM g WHERE grp IN (SELECT NULL FROM small)"
    "SELECT id FROM g WHERE grp = (SELECT k FROM small)"
    ;; INT64/DECIMAL columns against FLOAT64 constants
    "SELECT COUNT(*) FROM g WHERE amount > 123.45e0"
    "SELECT COUNT(*) FROM g WHERE amount = 370.1e0 OR amount <= 2.5e-1 OR amount >= 999.99e0"
    "SELECT COUNT(*) FROM g WHERE id <> 5e0 AND grp < 6.5e0 AND 1e300 > amount AND -1e300 < id"
    ;; a join probing an aggregation (build-side choice)
    "SELECT g.grp, x.c FROM g JOIN (SELECT grp, COUNT(*) AS c FROM gr GROUP BY grp) x ON x.grp = g.grp WHERE g.id < 400"))

(deftest latency.modes-agree
    (loop for morsel-rows in '(97 41)
          append (remove-if (lambda (sql) (same-in-all-modes-with-morsels sql morsel-rows))
                            *latency-queries*))
  nil)

(defun random-key-batch (n seed)
  "A batch of N rows: an INT64 column with NULLs and duplicates, a FLOAT64
column with NULLs, -0.0, 0.0 and duplicates, and a small INT64 column."
  (let ((state (sb-ext:seed-random-state seed)))
    (polyquery::make-batch
     n
     (vector (polyquery::build-vec :i64 n (lambda (i) (declare (ignore i))
                                            (if (zerop (random 9 state)) :null
                                                (- (random 2000 state) 1000))))
             (polyquery::build-vec :f64 n (lambda (i) (declare (ignore i))
                                            (case (random 12 state)
                                              (0 :null) (1 -0d0) (2 0d0)
                                              (t (/ (- (random 400 state) 200) 7d0)))))
             (polyquery::build-vec :i64 n (lambda (i) (declare (ignore i)) (random 5 state)))))))

(defun radix-agrees-p (batch keys)
  "True if the radix sort orders BATCH exactly like the comparator sort."
  (let ((radix (polyquery::sorted-permutation batch keys))
        (comparator (stable-sort (polyquery::identity-index-vector (polyquery::batch-count batch))
                                 (polyquery::make-index-sort-predicate batch keys))))
    (and (polyquery::radix-key-words batch keys)
         (equalp radix comparator))))

(deftest latency.radix-sort-matches-comparator-sort
    (loop for seed from 1 to 6
          for batch = (random-key-batch 3000 seed)
          always (every (lambda (keys) (radix-agrees-p batch keys))
                        '(((0 :int64 nil t))
                          ((1 :float64 t nil) (0 :int64 nil nil))
                          ((2 :int64 t t) (1 :float64 nil t) (0 :int64 t nil))
                          ((1 :float64 nil nil))
                          ((2 :int64 nil nil)))))
  t)

(deftest latency.first-true-integer
    (list (polyquery::first-true-integer (lambda (v) (>= v 17)))
          (polyquery::first-true-integer (lambda (v) (declare (ignore v)) t))
          (polyquery::first-true-integer (lambda (v) (declare (ignore v)) nil))
          (polyquery::first-true-integer (lambda (v) (> (/ v 100) 1/3))))
  (17 #.(- (expt 2 63)) nil 34))
