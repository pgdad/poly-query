;;;; estimates.lisp — predicate analysis and statistics-based estimates
;;;; (indexes-and-planning.md §3), shared by the logical optimizer (join
;;;; reordering) and the physical planner (index choice, segment skipping,
;;;; join build side).
;;;;
;;;; The conjuncts of a filter directly above a scan are analysed into
;;;; COLUMN-PREDICATEs (`column op constant`, `column IN (constants)`,
;;;; `column BETWEEN constant AND constant`). Their selectivity is estimated
;;;; from statistics (equality 1/distinct, ranges by linear interpolation
;;;; between min and max for numeric/temporal types, 1/3 otherwise).

(in-package #:polyquery)

(defstruct column-predicate
  conjunct                               ; the original BEXPR
  (column 0 :type fixnum)                ; position in the scan row
  op                                     ; := :< :<= :> :>= :in :between
  constants                              ; list of non-NULL constant values
  constant-types)                        ; their types, aligned

;;; ------------------------------------------------------------------
;;; Recognizing predicates

(defun plannable-constant (e)
  "Value of E if it is a non-NULL constant that is safe to evaluate during
planning (literals, casts, arithmetic), else NIL. Returns (values value ok)."
  (when (and (bexpr-constant-p e)
             (not (bexpr-some (lambda (x) (and (b-op-p x) (member (b-op-op x) '(:call :subquery :case))))
                              e)))
    (handler-case
        (let ((v (evaluate-constant e)))
          (if (null-value-p v) (values nil nil) (values v t)))
      (pq-error () (values nil nil)))))

(defun flip-comparison (op)
  (ecase op (:= :=) (:< :>) (:<= :>=) (:> :<) (:>= :<=)))

(defun analyse-conjunct (c)
  "A COLUMN-PREDICATE for the conjunct C, or NIL."
  (when (b-op-p c)
    (let ((op (b-op-op c)) (args (b-op-args c)))
      (flet ((pred (col op constants)
               (make-column-predicate :conjunct c :column (b-column-index col) :op op
                                      :constants (mapcar #'car constants)
                                      :constant-types (mapcar #'cdr constants)))
             (constant (e)
               (multiple-value-bind (v ok) (plannable-constant e)
                 (and ok (cons v (bexpr-type e))))))
        (case op
          ((:= :< :<= :> :>=)
           (destructuring-bind (a b) args
             (cond ((and (b-column-p a) (constant b)) (pred a op (list (constant b))))
                   ((and (b-column-p b) (constant a)) (pred b (flip-comparison op) (list (constant a))))
                   (t nil))))
          (:between
           (destructuring-bind (x low high) args
             (let ((lo (constant low)) (hi (constant high)))
               (and (b-column-p x) lo hi (pred x :between (list lo hi))))))
          (:in-list
           (destructuring-bind (x &rest items) args
             (when (and (b-column-p x)
                        (every (lambda (i) (and (bexpr-constant-p i)
                                                (or (and (b-literal-p i) (null-value-p (b-literal-value i)))
                                                    (constant i))))
                               items))
               (pred x :in (loop for i in items
                                 for k = (constant i)
                                 when k collect k)))))
          (t nil))))))

(defun analyse-conjuncts (conjuncts)
  (loop for c in conjuncts
        for p = (analyse-conjunct c)
        when p collect p))

;;; ------------------------------------------------------------------
;;; Numeric positions for interpolation

(defun interpolation-number (v type)
  "A rational placing V of TYPE on a common numeric axis (temporal values in
microseconds), or NIL for non-numeric types."
  (case (type-kind type)
    (:int64 v)
    (:decimal (/ v (pow10 (decimal-scale type))))
    (:float64 (rational v))
    (:date (* v +micros-per-day+))
    (:timestamp v)
    (t nil)))

(defun range-selectivity (lowers uppers col-type col-min col-max)
  "Estimated fraction of non-NULL values within all bounds. LOWERS/UPPERS are
lists of (value type inclusive)."
  (let ((lo (interpolation-number col-min col-type))
        (hi (interpolation-number col-max col-type)))
    (if (null lo)
        (expt 1/3 (min 2 (+ (length lowers) (length uppers))))
        (let ((a lo) (b hi))
          (dolist (l lowers)
            (let ((x (interpolation-number (first l) (second l))))
              (when x (setf a (max a x)))))
          (dolist (u uppers)
            (let ((x (interpolation-number (first u) (second u))))
              (when x (setf b (min b x)))))
          (cond ((> a b) 0)
                ((= lo hi) 1)
                (t (min 1 (/ (- b a) (- hi lo)))))))))

(defun predicate-bounds (p)
  "Range bounds of a range predicate: (values lowers uppers)."
  (let ((cs (column-predicate-constants p))
        (ts (column-predicate-constant-types p)))
    (ecase (column-predicate-op p)
      (:< (values '() (list (list (first cs) (first ts) nil))))
      (:<= (values '() (list (list (first cs) (first ts) t))))
      (:> (values (list (list (first cs) (first ts) nil)) '()))
      (:>= (values (list (list (first cs) (first ts) t)) '()))
      (:between (values (list (list (first cs) (first ts) t))
                        (list (list (second cs) (second ts) t)))))))

;;; ------------------------------------------------------------------
;;; Cardinality estimates

(defun predicate-selectivity (p table column-indexes)
  "Estimated selectivity of the column predicate P on a scan of TABLE."
  (let* ((k (svref column-indexes (column-predicate-column p)))
         (stats (table-column-statistics table k))
         (rows (max 1 (table-row-count table)))
         (non-null (/ (- rows (column-statistics-null-count stats)) rows))
         (distinct (max 1 (column-statistics-distinct-count stats)))
         (coltype (table-column-type table k)))
    (* non-null
       (case (column-predicate-op p)
         (:= (/ 1 distinct))
         (:in (min 1 (/ (length (column-predicate-constants p)) distinct)))
         (t (if (null-value-p (column-statistics-min stats))
                0
                (multiple-value-bind (l u) (predicate-bounds p)
                  (range-selectivity l u coltype (column-statistics-min stats)
                                     (column-statistics-max stats)))))))))

(defun estimate-filter-selectivity (predicate scan)
  "Estimated selectivity of the filter PREDICATE; SCAN is the LP-SCAN directly
below it (statistics are used for its column predicates) or NIL."
  (let ((result 1))
    (dolist (c (split-conjuncts predicate) result)
      (let ((p (and scan (analyse-conjunct c))))
        (setf result (* result (if p
                                   (predicate-selectivity p (lp-scan-table scan)
                                                          (lp-scan-column-indexes scan))
                                   1/3)))))))

(defun estimate-rows (node)
  "Estimated number of rows produced by the logical plan NODE."
  (etypecase node
    (lp-scan (table-row-count (lp-scan-table node)))
    (lp-values 1)
    (lp-filter (let ((child (lnode-child node)))
                 (* (estimate-rows child)
                    (estimate-filter-selectivity (lp-filter-predicate node)
                                                 (and (lp-scan-p child) child)))))
    (lp-join (destructuring-bind (l r) (mapcar #'estimate-rows (lnode-children node))
               (if (lp-join-condition node) (max l r) (* l r))))
    (lp-aggregate (if (lp-aggregate-group-by node) (estimate-rows (lnode-child node)) 1))
    ((or lp-project lp-distinct lp-sort lp-subquery-alias) (estimate-rows (lnode-child node)))
    (lp-union-all (reduce #'+ (lnode-children node) :key #'estimate-rows))
    (lp-limit (let ((n (estimate-rows (lnode-child node)))
                    (limit (lp-limit-limit node)))
                (if (and (b-literal-p limit) (integerp (b-literal-value limit)))
                    (min n (b-literal-value limit))
                    n)))))
