;;;; access.lisp — access path selection for filtered table scans
;;;; (indexes-and-planning.md §2-§3), used by the physical planner.
;;;;
;;;; The COLUMN-PREDICATEs of a filter directly above a scan (estimates.lisp)
;;;; are used to
;;;;   * choose an index scan: every index on the scanned table proposes an
;;;;     access from the predicates on its column; the access is estimated
;;;;     from statistics and the most selective one is used when it selects
;;;;     at most 10% of the rows (or the table is tiny, where either choice
;;;;     costs nothing);
;;;;   * skip segments (PQCF row groups) whose min/max statistics exclude a
;;;;     predicate, in table scans.

(in-package #:polyquery)

(defvar *planning-catalog* nil
  "Catalog whose indexes the planner may use (NIL: no index scans).")

(defvar *use-indexes* t
  "NIL disables index scans (query option use_indexes = false).")

(defparameter *index-selectivity-threshold* 1/10)

(defparameter *small-table-rows* 100
  "Tables with at most this many rows use an applicable index regardless of
the estimated selectivity: either access path is equally cheap there.")

;;; ------------------------------------------------------------------
;;; Index accesses

(defstruct index-access
  index
  kind                                   ; :POINTS or :RANGE
  points                                 ; :POINTS: list of (value . type)
  lowers uppers                          ; :RANGE: lists of (value type inclusive)
  conjuncts                              ; conjuncts fully answered by the access
  (selectivity 1))

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
