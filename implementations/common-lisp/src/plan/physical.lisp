;;;; physical.lisp — physical planning: choose an operator implementation for
;;;; every logical node, plan subqueries, and render plans as EXPLAIN JSON.
;;;;
;;;; Operator choices:
;;;;   Scan       -> TableScan (reads only the pruned columns)
;;;;   Filter(Scan) -> IndexScan (+ Filter for the remaining conjuncts) when
;;;;              an index answers a selective conjunct (access.lisp);
;;;;              otherwise Filter over a TableScan that skips segments whose
;;;;              statistics exclude a `column op constant` conjunct
;;;;   Filter(Scan) with a conjunct `scan-expr = parameter-expr` (a correlated
;;;;              subquery's equality with an outer column) -> HashLookupScan:
;;;;              the scan is hashed on scan-expr once and probed per evaluation
;;;;   Join       -> HashJoin when the condition has equi-join conjuncts
;;;;                 (left expr = right expr), the remaining conjuncts being a
;;;;                 residual; otherwise NestedLoopJoin. Inner hash joins
;;;;                 build on the input with the smaller estimated
;;;;                 cardinality, LEFT joins on the right input.
;;;;   Aggregate  -> HashAggregate
;;;;   Distinct   -> HashDistinct
;;;;   Sort+Limit -> TopN when the limit is a small constant, else Sort, Limit

(in-package #:polyquery)

(defstruct (pnode (:constructor nil))
  (children '())
  (columns '()))

(defstruct (pp-table-scan (:include pnode))
  table label
  (column-indexes #() :type simple-vector)
  (skips '()))                           ; SKIP-PREDICATEs for segment skipping

(defstruct (pp-index-scan (:include pnode))
  table label
  (column-indexes #() :type simple-vector)
  access)                                ; INDEX-ACCESS

(defstruct (pp-lookup-scan (:include pnode))
  table label
  (column-indexes #() :type simple-vector)
  key-exprs                              ; BEXPRs over the scan row
  probe-exprs                            ; parameter-only BEXPRs, compared with KEY-EXPRS
  residual)                              ; remaining filter conjuncts, or NIL

(defstruct (pp-values (:include pnode)))

(defstruct (pp-filter (:include pnode))
  predicate)

(defstruct (pp-project (:include pnode))
  exprs)

(defstruct (pp-nested-loop-join (:include pnode))
  kind condition)

(defstruct (pp-hash-join (:include pnode))
  kind
  (build :right)                         ; input hashed: :RIGHT or :LEFT (inner joins)
  left-keys                              ; BEXPRs over the left row
  right-keys                             ; BEXPRs over the right row
  residual)                              ; BEXPR over left ++ right, or NIL

(defstruct (pp-hash-aggregate (:include pnode))
  group-by aggregates)

(defstruct (pp-hash-distinct (:include pnode)))

(defstruct (pp-sort (:include pnode))
  keys)

(defstruct (pp-limit (:include pnode))
  limit offset)

(defstruct (pp-top-n (:include pnode))
  keys limit offset)

(defun pnode-child (node) (first (pnode-children node)))

;;; ------------------------------------------------------------------
;;; Entry point

(defun plan-bound-query (bq)
  "Full planning pipeline for an analysed query: logical plan, logical
optimization, physical plan (including the plans of nested subqueries)."
  (physical-plan (optimize-logical-plan (plan-query bq))))

;;; ------------------------------------------------------------------
;;; Logical -> physical

(defparameter *top-n-threshold* 100000
  "Largest constant LIMIT+OFFSET for which ORDER BY ... LIMIT uses TopN.")

(defun plan-expression-subqueries (exprs)
  "Plan every subquery appearing in EXPRS (once per subquery)."
  (dolist (e exprs)
    (when e
      (bexpr-walk (lambda (x)
                    (when (subquery-op-p x)
                      (let ((sq (b-op-info x)))
                        (unless (subquery-plan sq)
                          (setf (subquery-plan sq) (plan-bound-query (subquery-query sq)))))))
                  e))))

(defun equi-join-keys (condition left-width width)
  "Split CONDITION into hash-join keys. Returns (values left-keys right-keys
residual-conjuncts); right keys index the right input."
  (let ((lkeys '()) (rkeys '()) (residual '()))
    (dolist (c (and condition (split-conjuncts condition)))
      (let ((a (and (b-op-p c) (eq (b-op-op c) :=) (first (b-op-args c))))
            (b (and (b-op-p c) (eq (b-op-op c) :=) (second (b-op-args c)))))
        (flet ((left-side-p (e) (and (bexpr-column-indexes e) (columns-within-p e 0 left-width)))
               (right-side-p (e) (and (bexpr-column-indexes e) (columns-within-p e left-width width))))
          (cond ((and a (left-side-p a) (right-side-p b))
                 (push a lkeys) (push (bexpr-shift-columns b (- left-width)) rkeys))
                ((and a (left-side-p b) (right-side-p a))
                 (push b lkeys) (push (bexpr-shift-columns a (- left-width)) rkeys))
                (t (push c residual))))))
    (values (nreverse lkeys) (nreverse rkeys) (nreverse residual))))

(defun constant-limit-value (e)
  "Value of a LIMIT/OFFSET expression if it is a literal, else NIL."
  (cond ((null e) 0)
        ((and (b-literal-p e) (integerp (b-literal-value e))) (b-literal-value e))
        (t nil)))

(defun physical-plan (node)
  (let ((columns (lnode-columns node)))
    (flet ((child () (physical-plan (lnode-child node))))
      (etypecase node
        (lp-scan (make-pp-table-scan :table (lp-scan-table node) :label (lp-scan-label node)
                                     :column-indexes (lp-scan-column-indexes node)
                                     :columns columns))
        (lp-values (make-pp-values :columns columns))
        (lp-filter
         (plan-expression-subqueries (list (lp-filter-predicate node)))
         (or (and (lp-scan-p (lnode-child node))
                  (or (plan-lookup-scan node) (plan-filtered-scan node)))
             (make-pp-filter :children (list (child)) :predicate (lp-filter-predicate node)
                             :columns columns)))
        (lp-project
         (plan-expression-subqueries (lp-project-exprs node))
         (make-pp-project :children (list (child)) :exprs (lp-project-exprs node) :columns columns))
        (lp-join (physical-join node))
        (lp-aggregate
         (plan-expression-subqueries (append (lp-aggregate-group-by node)
                                             (lp-aggregate-aggregates node)))
         (make-pp-hash-aggregate :children (list (child)) :columns columns
                                 :group-by (lp-aggregate-group-by node)
                                 :aggregates (lp-aggregate-aggregates node)))
        (lp-distinct (make-pp-hash-distinct :children (list (child)) :columns columns))
        (lp-sort (make-pp-sort :children (list (child)) :keys (lp-sort-keys node) :columns columns))
        (lp-limit
         (let ((input (lnode-child node))
               (limit (constant-limit-value (lp-limit-limit node)))
               (offset (constant-limit-value (lp-limit-offset node))))
           (if (and (lp-sort-p input) (lp-limit-limit node) limit offset
                    (<= 0 limit) (<= 0 offset) (<= (+ limit offset) *top-n-threshold*))
               (make-pp-top-n :children (list (physical-plan (lnode-child input)))
                              :keys (lp-sort-keys input) :limit (lp-limit-limit node)
                              :offset (lp-limit-offset node) :columns columns)
               (make-pp-limit :children (list (child)) :limit (lp-limit-limit node)
                              :offset (lp-limit-offset node) :columns columns))))))))

(defun parameter-only-p (e)
  "True if E reads no columns but depends on correlation parameters."
  (and (null (bexpr-column-indexes e))
       (bexpr-some #'b-param-p e)
       (not (bexpr-some #'subquery-op-p e))))

(defun plan-lookup-scan (node)
  "HashLookupScan for a Filter over a Scan with `expr = parameter` conjuncts, or NIL."
  (let ((scan (lnode-child node))
        (keys '()) (probes '()) (residual '()))
    (dolist (c (split-conjuncts (lp-filter-predicate node)))
      (let ((a (and (b-op-p c) (eq (b-op-op c) :=) (first (b-op-args c))))
            (b (and (b-op-p c) (eq (b-op-op c) :=) (second (b-op-args c)))))
        (flet ((key-side-p (e) (and (bexpr-column-indexes e) (not (bexpr-some #'b-param-p e))
                                    (not (bexpr-some #'subquery-op-p e)))))
          (cond ((and a (key-side-p a) (parameter-only-p b)) (push a keys) (push b probes))
                ((and a (key-side-p b) (parameter-only-p a)) (push b keys) (push a probes))
                (t (push c residual))))))
    (when keys
      (make-pp-lookup-scan :table (lp-scan-table scan) :label (lp-scan-label scan)
                           :column-indexes (lp-scan-column-indexes scan)
                           :key-exprs (nreverse keys) :probe-exprs (nreverse probes)
                           :residual (conjoin (nreverse residual))
                           :columns (lnode-columns node)))))

(defun plan-filtered-scan (node)
  "IndexScan or segment-skipping TableScan (with the residual Filter above)
for a Filter directly over a Scan."
  (let* ((scan (lnode-child node))
         (table (lp-scan-table scan))
         (column-indexes (lp-scan-column-indexes scan))
         (conjuncts (split-conjuncts (lp-filter-predicate node)))
         (preds (analyse-conjuncts conjuncts))
         (access (choose-index-access table column-indexes preds))
         (residual (conjoin (if access
                                (remove-if (lambda (c) (member c (index-access-conjuncts access)))
                                           conjuncts)
                                conjuncts)))
         (input (if access
                    (make-pp-index-scan :table table :label (lp-scan-label scan)
                                        :column-indexes column-indexes :access access
                                        :columns (lnode-columns scan))
                    (make-pp-table-scan :table table :label (lp-scan-label scan)
                                        :column-indexes column-indexes
                                        :skips (make-skip-predicates preds column-indexes)
                                        :columns (lnode-columns scan)))))
    (if residual
        (make-pp-filter :children (list input) :predicate residual :columns (lnode-columns node))
        input)))

(defun plan-invariant-p (node)
  "True if the rows NODE produces cannot change between executions of an
enclosing correlated subquery (no correlation parameters anywhere)."
  (and (every (lambda (e)
                (or (null e)
                    (not (bexpr-some (lambda (x)
                                       (or (b-param-p x)
                                           (and (subquery-op-p x)
                                                (not (subquery-cacheable (b-op-info x))))))
                                     e))))
              (node-expressions node))
       (every #'plan-invariant-p (pnode-children node))))

(defun physical-join (node)
  (destructuring-bind (left right) (lnode-children node)
    (let ((kind (lp-join-kind node))
          (condition (lp-join-condition node))
          (pleft (physical-plan left))
          (pright (physical-plan right)))
      (plan-expression-subqueries (list condition))
      (multiple-value-bind (lkeys rkeys residual)
          (equi-join-keys condition (lnode-width left) (lnode-width node))
        (if lkeys
            (make-pp-hash-join :kind kind :children (list pleft pright) :columns (lnode-columns node)
                               :build (if (and (eq kind :inner)
                                               (< (estimate-rows left) (estimate-rows right)))
                                          :left
                                          :right)
                               :left-keys lkeys :right-keys rkeys :residual (conjoin residual))
            (make-pp-nested-loop-join :kind (if (and (null condition) (eq kind :inner)) :cross kind)
                                      :children (list pleft pright)
                                      :columns (lnode-columns node) :condition condition))))))

;;; ------------------------------------------------------------------
;;; EXPLAIN rendering (indexes-and-planning.md §4)

(defun expression-subqueries (exprs)
  "The planned SUBQUERY descriptors used in EXPRS, in order of appearance."
  (let ((found '()))
    (dolist (e exprs (nreverse found))
      (when e
        (bexpr-walk (lambda (x)
                      (when (and (subquery-op-p x) (subquery-plan (b-op-info x)))
                        (pushnew (b-op-info x) found)))
                    e)))))

(defun node-expressions (node)
  (typecase node
    (pp-filter (list (pp-filter-predicate node)))
    (pp-project (pp-project-exprs node))
    (pp-nested-loop-join (list (pp-nested-loop-join-condition node)))
    (pp-hash-join (append (pp-hash-join-left-keys node) (pp-hash-join-right-keys node)
                          (list (pp-hash-join-residual node))))
    (pp-hash-aggregate (append (pp-hash-aggregate-group-by node) (pp-hash-aggregate-aggregates node)))
    (pp-lookup-scan (append (pp-lookup-scan-key-exprs node) (pp-lookup-scan-probe-exprs node)
                            (list (pp-lookup-scan-residual node))))
    (pp-limit (list (pp-limit-limit node) (pp-limit-offset node)))
    (pp-top-n (list (pp-top-n-limit node) (pp-top-n-offset node)))
    (t nil)))

(defun describe-sort-keys (node keys)
  (loop for (pos nil desc nulls-first) in keys
        collect (format nil "~A ~:[ASC~;DESC~] NULLS ~:[LAST~;FIRST~]"
                        (column-def-name (nth pos (pnode-columns (pnode-child node))))
                        desc nulls-first)))

(defun describe-skips (node)
  (let ((table (pp-table-scan-table node)))
    (loop for s in (pp-table-scan-skips node)
          collect (format nil "~A ~(~A~) ~{~A~^, ~}"
                          (column-def-name (svref (table-columns table) (skip-predicate-column s)))
                          (skip-predicate-op s)
                          (mapcar (lambda (v ty) (value-to-text v ty))
                                  (skip-predicate-constants s) (skip-predicate-constant-types s))))))

(defun join-type-name (kind)
  (ecase kind (:inner "INNER") (:left "LEFT") (:cross "CROSS")))

(defun explain-properties (node)
  (flet ((describe-all (exprs) (mapcar #'bexpr-describe exprs))
         (maybe (e) (if e (bexpr-describe e) :null)))
    (etypecase node
      (pp-table-scan (list* "op" "TableScan" "table" (table-name (pp-table-scan-table node))
                            "alias" (pp-table-scan-label node)
                            "columns" (mapcar #'column-def-name (pnode-columns node))
                            "layout" (table-layout-name (pp-table-scan-table node))
                            (when (pp-table-scan-skips node)
                              (list "segment_skipping" (describe-skips node)))))
      (pp-index-scan (let ((access (pp-index-scan-access node)))
                       (list "op" "IndexScan" "table" (table-name (pp-index-scan-table node))
                             "alias" (pp-index-scan-label node)
                             "index" (table-index-name (index-access-index access))
                             "kind" (table-index-kind-name (index-access-index access))
                             "columns" (mapcar #'column-def-name (pnode-columns node))
                             "lookup" (describe-all (index-access-conjuncts access))
                             "selectivity" (coerce (index-access-selectivity access) 'double-float))))
      (pp-lookup-scan (list "op" "HashLookupScan" "table" (table-name (pp-lookup-scan-table node))
                            "alias" (pp-lookup-scan-label node)
                            "columns" (mapcar #'column-def-name (pnode-columns node))
                            "keys" (describe-all (pp-lookup-scan-key-exprs node))
                            "probes" (describe-all (pp-lookup-scan-probe-exprs node))
                            "residual" (maybe (pp-lookup-scan-residual node))))
      (pp-values (list "op" "Values" "rows" 1))
      (pp-filter (list "op" "Filter" "predicate" (bexpr-describe (pp-filter-predicate node))))
      (pp-project (list "op" "Project" "columns" (mapcar #'column-def-name (pnode-columns node))
                        "exprs" (describe-all (pp-project-exprs node))))
      (pp-nested-loop-join (list "op" "NestedLoopJoin"
                                 "join_type" (join-type-name (pp-nested-loop-join-kind node))
                                 "condition" (maybe (pp-nested-loop-join-condition node))))
      (pp-hash-join (list "op" "HashJoin" "join_type" (join-type-name (pp-hash-join-kind node))
                          "build" (string-downcase (symbol-name (pp-hash-join-build node)))
                          "left_keys" (describe-all (pp-hash-join-left-keys node))
                          "right_keys" (describe-all (pp-hash-join-right-keys node))
                          "residual" (maybe (pp-hash-join-residual node))))
      (pp-hash-aggregate (list "op" "Aggregate" "strategy" "hash"
                               "group_by" (describe-all (pp-hash-aggregate-group-by node))
                               "aggregates" (describe-all (pp-hash-aggregate-aggregates node))))
      (pp-hash-distinct (list "op" "Distinct" "strategy" "hash"))
      (pp-sort (list "op" "Sort" "keys" (describe-sort-keys node (pp-sort-keys node))))
      (pp-limit (list "op" "Limit" "limit" (maybe (pp-limit-limit node))
                      "offset" (maybe (pp-limit-offset node))))
      (pp-top-n (list "op" "TopN" "keys" (describe-sort-keys node (pp-top-n-keys node))
                      "limit" (maybe (pp-top-n-limit node))
                      "offset" (maybe (pp-top-n-offset node)))))))

(defun explain-plan-json (node)
  "The EXPLAIN JSON object of physical plan NODE. The plans of subqueries
evaluated by NODE follow its input children, each wrapped in a `Subquery`
node (they are separate executions, not inputs)."
  (apply #'jobj
         (append (explain-properties node)
                 (list "children"
                       (append (mapcar #'explain-plan-json (pnode-children node))
                               (mapcar (lambda (sq)
                                         (jobj "op" "Subquery"
                                               "kind" (string-downcase
                                                       (symbol-name (subquery-kind sq)))
                                               "correlated" (if (plusp (subquery-param-count sq))
                                                                :true :false)
                                               "children" (list (explain-plan-json
                                                                 (subquery-plan sq)))))
                                       (expression-subqueries (node-expressions node))))))))
