;;;; access.lisp — access path selection for filtered table scans
;;;; (indexes-and-planning.md §2-§3).
;;;;
;;;; The conjuncts of a filter directly above a scan are analysed into
;;;; COLUMN-PREDICATEs (`column op constant`, `column IN (constants)`,
;;;; `column BETWEEN constant AND constant`). They are used to
;;;;   * choose an index scan: every index on the scanned table proposes an
;;;;     access from the predicates on its column; the access is estimated
;;;;     from statistics (equality 1/distinct, ranges by linear interpolation
;;;;     between min and max for numeric/temporal types, 1/3 otherwise) and
;;;;     the most selective one is used when it selects at most 10% of the
;;;;     rows (or the table is tiny, where either choice costs nothing);
;;;;   * skip segments (PQCF row groups) whose min/max statistics exclude a
;;;;     predicate, in table scans;
;;;;   * estimate filter selectivities for the join build-side choice.

(in-package #:polyquery)

(defvar *planning-catalog* nil
  "Catalog whose indexes the planner may use (NIL: no index scans).")

(defvar *use-indexes* t
  "NIL disables index scans (query option use_indexes = false).")

(defparameter *index-selectivity-threshold* 1/10)

(defparameter *small-table-rows* 100
  "Tables with at most this many rows use an applicable index regardless of
the estimated selectivity: either access path is equally cheap there.")

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

;;; ------------------------------------------------------------------
;;; Index accesses

(defstruct index-access
  index
  kind                                   ; :POINTS or :RANGE
  points                                 ; :POINTS: list of (value . type)
  lowers uppers                          ; :RANGE: lists of (value type inclusive)
  conjuncts                              ; conjuncts fully answered by the access
  (selectivity 1))

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

(defun hash-probe-key (c ctype coltype)
  "Key of the column type under which C (of CTYPE) is found in a hash index on
a column of COLTYPE. Returns (values key status), STATUS being :OK, :NONE
(no column value equals C) or :UNUSABLE (the index cannot answer exactly)."
  (let ((ck (type-kind ctype)) (tk (type-kind coltype)))
    (flet ((divide (num den)
             (multiple-value-bind (q r) (floor num den)
               (if (zerop r) (values q :ok) (values nil :none)))))
      (cond
        ((and (eq ck tk) (not (eq tk :decimal))) (values c :ok))
        ((eq tk :int64)
         (case ck
           (:decimal (divide c (pow10 (decimal-scale ctype))))
           (:float64 (cond ((/= c (ftruncate c)) (values nil :none))
                           ((< (abs c) (expt 2d0 53)) (values (truncate c) :ok))
                           (t (values nil :unusable))))
           (t (values nil :unusable))))
        ((eq tk :decimal)
         (let ((s1 (decimal-scale coltype)))
           (case ck
             (:int64 (let ((v (* c (pow10 s1))))
                       (if (fits-precision-p v +max-decimal-precision+) (values v :ok) (values nil :unusable))))
             (:decimal (let* ((s2 (decimal-scale ctype)) (m (max s1 s2)))
                         (divide (* c (pow10 (- m s2))) (pow10 (- m s1)))))
             (t (values nil :unusable)))))
        ((eq tk :float64)
         (case ck
           (:int64 (values (coerce c 'double-float) :ok))
           (:decimal (values (rational-to-double (/ c (pow10 (decimal-scale ctype)))) :ok))
           (t (values nil :unusable))))
        ((and (eq tk :date) (eq ck :timestamp)) (divide c +micros-per-day+))
        ((and (eq tk :timestamp) (eq ck :date)) (values (* c +micros-per-day+) :ok))
        (t (values nil :unusable))))))

(defun hash-access-usable-p (index points)
  (let ((coltype (table-column-type (table-index-table index) (table-index-column index))))
    (every (lambda (pt) (not (eq (nth-value 1 (hash-probe-key (car pt) (cdr pt) coltype)) :unusable)))
           points)))

(defun propose-index-access (index preds rows)
  "The best access INDEX offers for the predicates PREDS on its column, or NIL."
  (let* ((table (table-index-table index))
         (k (table-index-column index))
         (coltype (table-column-type table k))
         (distinct (max 1 (table-index-distinct-count index)))
         (best nil))
    (flet ((consider (access)
             (when (or (null best) (< (index-access-selectivity access) (index-access-selectivity best)))
               (setf best access))))
      ;; Equality / IN: one predicate is enough.
      (dolist (p preds)
        (when (member (column-predicate-op p) '(:= :in))
          (let ((points (mapcar #'cons (column-predicate-constants p)
                                (column-predicate-constant-types p))))
            (when (or (eq (table-index-kind index) :btree) (hash-access-usable-p index points))
              (consider (make-index-access :index index :kind :points :points points
                                           :conjuncts (list (column-predicate-conjunct p))
                                           :selectivity (min 1 (/ (length points) distinct))))))))
      ;; Ranges (BTREE only): all range predicates on the column combine.
      (when (eq (table-index-kind index) :btree)
        (let ((lowers '()) (uppers '()) (used '()))
          (dolist (p preds)
            (when (member (column-predicate-op p) '(:< :<= :> :>= :between))
              (multiple-value-bind (l u) (predicate-bounds p)
                (setf lowers (append lowers l) uppers (append uppers u))
                (push (column-predicate-conjunct p) used))))
          (when used
            (let ((keys (table-index-keys index)))
              (consider (make-index-access
                         :index index :kind :range :lowers lowers :uppers uppers
                         :conjuncts (nreverse used)
                         :selectivity (if (zerop (length keys))
                                          0
                                          (* (/ (length keys) (max 1 rows))
                                             (range-selectivity lowers uppers coltype (svref keys 0)
                                                                (svref keys (1- (length keys))))))))))))
      best)))

(defun choose-index-access (table column-indexes preds)
  "The index access to use for a filtered scan of TABLE (scan positions map to
table columns through COLUMN-INDEXES), or NIL for a full scan."
  (when (and *use-indexes* *planning-catalog* preds)
    (let ((rows (table-row-count table))
          (best nil))
      (dolist (index (catalog-table-indexes *planning-catalog* table))
        (let* ((k (table-index-column index))
               (on-column (remove-if-not (lambda (p)
                                           (= (svref column-indexes (column-predicate-column p)) k))
                                         preds))
               (access (and on-column (propose-index-access index on-column rows))))
          (when (and access
                     (or (null best) (< (index-access-selectivity access) (index-access-selectivity best))))
            (setf best access))))
      (when (and best (or (<= (index-access-selectivity best) *index-selectivity-threshold*)
                          (<= rows *small-table-rows*)))
        best))))

;;; ------------------------------------------------------------------
;;; Executing index accesses

(defun merge-row-ids (vectors)
  "Ascending, duplicate-free union of the row-id VECTORS."
  (let ((all (sort (apply #'concatenate 'simple-vector vectors) #'<)))
    (if (< (length all) 2)
        all
        (let ((out (make-array (length all) :fill-pointer 0)))
          (loop for id across all
                for prev = nil then last
                for last = id
                unless (eql id prev) do (vector-push id out))
          (coerce out 'simple-vector)))))

(defun bound-comparator (coltype bound)
  "(compare-fn inclusive) for a btree bound (value type inclusive)."
  (destructuring-bind (value type inclusive) bound
    (let ((cmp (make-value-comparator coltype type)))
      (declare (type function cmp))
      (list (lambda (key) (funcall cmp key value)) inclusive))))

(defun index-access-row-ids (access)
  "Ascending row ids selected by ACCESS."
  (let* ((index (index-access-index access))
         (coltype (table-column-type (table-index-table index) (table-index-column index))))
    (ecase (index-access-kind access)
      (:points
       (merge-row-ids
        (loop for (value . type) in (index-access-points access)
              collect (ecase (table-index-kind index)
                        (:hash (multiple-value-bind (key status) (hash-probe-key value type coltype)
                                 (if (eq status :ok) (hash-index-lookup index key) #())))
                        (:btree (let ((b (list value type t)))
                                  (btree-index-range index (bound-comparator coltype b)
                                                     (bound-comparator coltype b))))))))
      (:range
       ;; Each bound narrows the sorted key range: take the tightest.
       (let* ((keys (table-index-keys index))
              (start 0) (end (length keys)))
         (dolist (b (index-access-lowers access))
           (destructuring-bind (cmp inclusive) (bound-comparator coltype b)
             (declare (type function cmp))
             (setf start (max start (btree-lower-bound
                                     keys (if inclusive
                                              (lambda (k) (>= (the fixnum (funcall cmp k)) 0))
                                              (lambda (k) (> (the fixnum (funcall cmp k)) 0))))))))
         (dolist (b (index-access-uppers access))
           (destructuring-bind (cmp inclusive) (bound-comparator coltype b)
             (declare (type function cmp))
             (setf end (min end (btree-lower-bound
                                 keys (if inclusive
                                          (lambda (k) (> (the fixnum (funcall cmp k)) 0))
                                          (lambda (k) (>= (the fixnum (funcall cmp k)) 0))))))))
         (if (< start end)
             (sort (subseq (table-index-ids index) start end) #'<)
             #()))))))

;;; ------------------------------------------------------------------
;;; Segment skipping

(defstruct skip-predicate
  (column 0 :type fixnum)                ; table column
  op constants constant-types)

(defun make-skip-predicates (preds column-indexes)
  (loop for p in preds
        collect (make-skip-predicate :column (svref column-indexes (column-predicate-column p))
                                     :op (column-predicate-op p)
                                     :constants (column-predicate-constants p)
                                     :constant-types (column-predicate-constant-types p))))

(defun skip-test (table s)
  "Function (segment) -> true when the segment's statistics prove that no row
satisfies the SKIP-PREDICATE S."
  (let* ((k (skip-predicate-column s))
         (coltype (table-column-type table k))
         (op (skip-predicate-op s))
         (cmps (coerce (mapcar (lambda (ty) (make-value-comparator coltype ty))
                               (skip-predicate-constant-types s))
                       'simple-vector))
         (cs (coerce (skip-predicate-constants s) 'simple-vector)))
    (flet ((excluded-p (lo hi)
             (flet ((c (i v) (funcall (the function (svref cmps i)) v (svref cs i))))
               (ecase op
                 (:= (or (plusp (c 0 lo)) (minusp (c 0 hi))))
                 (:< (>= (c 0 lo) 0))
                 (:<= (> (c 0 lo) 0))
                 (:> (<= (c 0 hi) 0))
                 (:>= (< (c 0 hi) 0))
                 (:between (or (minusp (c 0 hi)) (plusp (c 1 lo))))
                 (:in (loop for i below (length cs)
                            always (or (plusp (c i lo)) (minusp (c i hi)))))))))
      (lambda (segment)
        (let ((st (segment-chunk-stats segment k)))
          (and st
               (let ((nulls (chunk-stats-null-count st))
                     (lo (chunk-stats-min st))
                     (hi (chunk-stats-max st)))
                 (or (and nulls (= nulls (segment-count segment)))
                     (and (not (null lo)) (not (null hi)) (excluded-p lo hi))))))))))

(defun compile-skip-test (table skips)
  "Function (segment) -> true when the segment can be skipped because its
statistics exclude one of SKIPS, or NIL when there is nothing to test."
  (when skips
    (let ((tests (mapcar (lambda (s) (skip-test table s)) skips)))
      (lambda (segment)
        (some (lambda (test) (funcall (the function test) segment)) tests)))))

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
    ((or lp-project lp-distinct lp-sort) (estimate-rows (lnode-child node)))
    (lp-limit (let ((n (estimate-rows (lnode-child node)))
                    (limit (lp-limit-limit node)))
                (if (and (b-literal-p limit) (integerp (b-literal-value limit)))
                    (min n (b-literal-value limit))
                    n)))))
