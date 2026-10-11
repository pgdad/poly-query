;;;; test-phase5.lisp — Phase 5: execution options, vectorized and parallel
;;;; execution, join algorithms, logical optimizer rewrites.

(in-package #:polyquery-tests)

(defun generated-csv (n)
  "CSV text of N rows with integer, decimal, float, string, boolean and date
columns, including NULLs."
  (with-output-to-string (s)
    (write-line "id,grp,amount,ratio,label,flag,day" s)
    (dotimes (i n)
      (format s "~D,~A,~A,~A,~A,~A,~A~%"
              i
              (if (zerop (mod i 11)) "" (mod (* i 7) 13))
              (if (zerop (mod i 17)) "" (format nil "~D.~2,'0D" (mod (* i 37) 1000) (mod i 100)))
              (if (zerop (mod i 19)) "" (format nil "~De-1" (- (mod (* i 13) 200) 100)))
              (if (zerop (mod i 23)) "" (nth (mod i 5) '("alpha" "beta" "gamma" "delta" "eps")))
              (if (zerop (mod i 29)) "" (if (evenp (floor i 3)) "true" "false"))
              (format nil "2024-~2,'0D-~2,'0D" (1+ (mod i 12)) (1+ (mod i 28)))))))

(defun phase5-session ()
  (let ((session (make-session (make-engine-config :data-dir "/nonexistent/"))))
    (handle-request session (jobj "op" "load" "table" "g" "format" "csv" "data" (generated-csv 3000)))
    (handle-request session (jobj "op" "load" "table" "gr" "format" "csv" "data" (generated-csv 3000)
                                  "layout" "row"))
    (handle-request session (jobj "op" "load" "table" "small" "format" "csv"
                                  "data" (format nil "k,name~%1,one~%2,two~%3,three~%5,five~%")))
    session))

(defparameter *phase5-session* nil)

(defun options (&rest args)
  (apply #'polyquery::make-exec-options args))

(defun run-with (sql options)
  "Rows (as lists) of SQL under OPTIONS, or the error code."
  (unless *phase5-session* (setf *phase5-session* (phase5-session)))
  (handler-case
      (let ((polyquery::*morsel-rows* 97))  ; many morsels: exercise the parallel paths
        (mapcar (lambda (row) (coerce row 'list))
                (polyquery::query-result-rows
                 (execute-sql *phase5-session* sql :options options))))
    (pq-error (e) (pq-error-code e))))

(defun canonical (rows)
  "Comparable form of a result: sorted printed rows, FLOAT64 values rounded
to 9 significant digits (summation order is implementation-defined)."
  (if (listp rows)
      (sort (mapcar (lambda (row)
                      (prin1-to-string
                       (mapcar (lambda (v) (if (floatp v) (format nil "~,8,,,,,'eE" v) v)) row)))
                    rows)
            #'string<)
      rows))

(defparameter *option-matrix*
  (list (options :mode :vectorized)
        (options :mode :vectorized :threads 4)
        (options :mode :vectorized :threads 3 :join :merge)
        (options :mode :vectorized :threads 2 :join :nested-loop :optimize nil)
        (options :mode :row :join :merge)
        (options :mode :row :join :nested-loop :optimize nil)))

(defun same-in-all-modes (sql)
  "True if SQL gives the row-mode result under every option combination."
  (let ((reference (canonical (run-with sql (options :mode :row)))))
    (every (lambda (o) (equal (canonical (run-with sql o)) reference)) *option-matrix*)))

(defparameter *equivalence-queries*
  '("SELECT * FROM g WHERE amount > 500 AND label <> 'beta'"
    "SELECT grp, COUNT(*), COUNT(label), SUM(amount), AVG(ratio), MIN(day), MAX(label) FROM g GROUP BY grp"
    "SELECT COUNT(DISTINCT label), SUM(DISTINCT grp), AVG(DISTINCT amount) FROM g"
    "SELECT flag, label, COUNT(*) FROM gr GROUP BY flag, label HAVING COUNT(*) > 10"
    "SELECT DISTINCT grp, flag FROM g"
    "SELECT a.id, b.label FROM g a JOIN gr b ON a.id = b.id WHERE a.grp = 3"
    "SELECT s.name, COUNT(*) FROM g JOIN small s ON s.k = g.grp GROUP BY s.name"
    "SELECT s.name, COUNT(g.id) FROM small s LEFT JOIN g ON g.grp = s.k AND g.amount > 900 GROUP BY s.name"
    "SELECT id, CASE WHEN ratio > 0 THEN 'pos' WHEN ratio < 0 THEN 'neg' END, COALESCE(label, 'none') FROM g"
    "SELECT id FROM g WHERE id % 100 = 0 AND (100 / (grp - 3)) > 0"
    "SELECT id, amount FROM g ORDER BY amount DESC NULLS LAST, id LIMIT 7 OFFSET 2"
    "SELECT label, day FROM g ORDER BY label NULLS FIRST, day DESC, id"
    "SELECT id FROM g WHERE grp IN (SELECT k FROM small) AND EXISTS (SELECT 1 FROM small s WHERE s.k = g.grp)"
    "SELECT SUM(id * 4611686018427387) FROM g"
    "SELECT id / (grp - grp) FROM g"
    "SELECT COUNT(*) FROM g a, gr b, small c WHERE a.id = b.id AND b.grp = c.k"
    ;; regressions: NULL-typed join keys (merge join), LIMIT over a projection
    "SELECT g.id FROM g JOIN (SELECT NULL AS z FROM small) x ON g.id = x.z"
    "SELECT g.id, x.z FROM g LEFT JOIN (SELECT NULL AS z FROM small) x ON g.id = x.z"
    "SELECT id, 100 / (id - 2500) FROM g LIMIT 2400"
    "SELECT COUNT(*) FROM g JOIN small ON g.grp = small.k AND FALSE WHERE CAST(g.label AS INT64) > 0"))

(deftest phase5.modes-agree
    (remove-if #'same-in-all-modes *equivalence-queries*)
  nil)

(deftest phase5.errors-in-every-mode
    (mapcar (lambda (o) (run-with "SELECT SUM(id * 4611686018427387) FROM g" o)) *option-matrix*)
  ("NUMERIC_OVERFLOW" "NUMERIC_OVERFLOW" "NUMERIC_OVERFLOW" "NUMERIC_OVERFLOW"
   "NUMERIC_OVERFLOW" "NUMERIC_OVERFLOW"))

;;; Options

(defun option-error (json-options)
  (handler-case (progn (polyquery::query-exec-options (parse-json json-options)) :ok)
    (pq-error (e) (pq-error-code e))))

(deftest phase5.option-validation
    (mapcar #'option-error '("{\"mode\":\"quantum\"}" "{\"join\":\"teleport\"}" "{\"threads\":0}"
                             "{\"optimize\":1}" "{\"mode\":\"vectorized\",\"threads\":8,\"join\":\"merge\"}"))
  ("UNSUPPORTED" "UNSUPPORTED" "UNSUPPORTED" "INVALID_REQUEST" :ok))

;;; Plans

(defun plan-ops-with (sql options)
  (unless *phase5-session* (setf *phase5-session* (phase5-session)))
  (let ((ops '()))
    (labels ((walk (node)
               (push (polyquery::json-get node "op") ops)
               (mapc #'walk (polyquery::json-get node "children"))))
      (walk (polyquery::explain-sql *phase5-session* sql :options options)))
    (nreverse ops)))

(deftest phase5.forced-join-algorithms
    (loop for join in '(:hash :merge :nested-loop)
          collect (find-if (lambda (op) (search "Join" op))
                           (plan-ops-with "SELECT 1 FROM g JOIN small ON g.grp = small.k"
                                          (options :join join))))
  ("HashJoin" "MergeJoin" "NestedLoopJoin"))

(deftest phase5.non-equi-join-is-nested-loop
    (find-if (lambda (op) (search "Join" op))
             (plan-ops-with "SELECT 1 FROM g JOIN small ON g.grp < small.k" (options :join :merge)))
  "NestedLoopJoin")

(deftest phase5.join-reordering-avoids-cross-product
    (list (member "NestedLoopJoin"
                  (plan-ops-with "SELECT 1 FROM g a, small c, gr b WHERE a.id = b.id AND b.grp = c.k"
                                 (options))
                  :test #'equal)
          (and (member "NestedLoopJoin"
                       (plan-ops-with "SELECT 1 FROM g a, small c, gr b WHERE a.id = b.id AND b.grp = c.k"
                                      (options :optimize nil))
                       :test #'equal)
               t))
  (nil t))

(defun explain-exprs (sql options)
  (polyquery::json-get (polyquery::explain-sql *phase5-session* sql :options options) "exprs"))

(deftest phase5.constant-folding
    (list (explain-exprs "SELECT 1 + 2 * 3, k FROM small" (options))
          (explain-exprs "SELECT 1 + 2 * 3, k FROM small" (options :optimize nil)))
  (("7" "k") ("(1 + (2 * 3))" "k")))

(deftest phase5.false-filter-removed
    (plan-ops-with "SELECT k FROM small WHERE 1 = 1 AND NOT (k < 2)" (options))
  ("Project" "Filter" "TableScan"))

;;; Vectors, key tables, aggregate states

(deftest phase5.vec-gather
    (let* ((v (polyquery::build-vec :i64 4 (lambda (i) (if (= i 2) :null (* i 10)))))
           (g (polyquery::vec-gather v (coerce #(3 2 -1 0) '(simple-array fixnum (*))) 4)))
      (loop for i below 4 collect (polyquery::vec-ref g i)))
  (30 :null :null 0))

(deftest phase5.key-table
    (let* ((table (polyquery::make-key-table 2 2))
           (keys (list (polyquery::build-vec :i64 6 (lambda (i) (if (= i 5) :null (mod i 3))))
                       (polyquery::build-vec :any 6 (lambda (i) (if (evenp i) "x" "y")))))
           (gids (polyquery::make-index-vector 6)))
      (polyquery::key-table-map-batch table keys 6 gids t)
      (list (coerce gids 'list) (polyquery::key-table-count table)
            (coerce (polyquery::key-table-map-batch table keys 6 (polyquery::make-index-vector 6) nil)
                    'list)))
  ((0 1 2 3 4 5) 6 (0 1 2 3 4 5)))

(deftest phase5.integer-key-table
    (let* ((table (polyquery::make-key-table 1 2 '(:i64)))
           (keys (list (polyquery::build-vec :i64 8 (lambda (i) (if (= i 3) :null (* (mod i 5) 1000000007))))))
           (gids (polyquery::make-index-vector 8)))
      (polyquery::key-table-map-batch table keys 8 gids t)
      (list (coerce gids 'list)
            (loop for g below (polyquery::key-table-count table)
                  collect (polyquery::key-table-key table 0 g))
            (coerce (polyquery::key-table-map-batch
                     table (list (polyquery::build-vec :i64 3 (lambda (i) (nth i '(4000000028 7 :null)))))
                     3 (polyquery::make-index-vector 3) nil)
                    'list)))
  ((0 1 2 3 4 0 1 2) (0 1000000007 2000000014 :null 4000000028) (4 -1 3)))

(deftest phase5.group-state-merge
    (let* ((agg (polyquery::make-b-agg :int64 :sum (list (polyquery::make-b-column :int64 0 "x")) nil))
           (a (polyquery::make-group-state '(:any) (list agg)))
           (b (polyquery::make-group-state '(:any) (list agg))))
      (flet ((feed (gs keys values)
               (polyquery::group-state-consume
                gs (list (polyquery::build-vec :any (length keys) (lambda (i) (nth i keys))))
                (list (polyquery::build-vec :i64 (length values) (lambda (i) (nth i values))))
                (length keys))))
        (feed a '("p" "q" "p") '(1 2 3))
        (feed b '("r" "p") '(10 20))
        (polyquery::group-state-merge a b)
        (let ((batch (polyquery::group-state-batch a 0 3 #(:any) #(:i64))))
          (loop for i below 3 collect (coerce (polyquery::batch-row batch i) 'list)))))
  (("p" 24) ("q" 2) ("r" 10)))
