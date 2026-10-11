;;;; vaggregates.lisp — columnar, mergeable aggregate states for the
;;;; vectorized executor (functions.md §2).
;;;;
;;;; An AGG-STATE holds the running values of one aggregate for *all* groups
;;;; in dense arrays indexed by group id, and is updated a batch at a time
;;;; from the argument VEC and the rows' group ids. Two states of the same
;;;; aggregate can be merged (parallel aggregation: each worker aggregates
;;;; its share of the input, the partial states are then merged). Results
;;;; are identical to the row accumulators of aggregates.lisp: INT64/DECIMAL
;;;; sums are exact and range checked when the result is produced.

(in-package #:polyquery)

(defgeneric agg-reserve (state groups)
  (:documentation "Make room for group ids below GROUPS."))

(defgeneric agg-update (state gids vec n)
  (:documentation "Accumulate rows [0, N) of the argument VEC (NIL for
COUNT(*)) into the groups GIDS."))

(defgeneric agg-merge (state other mapping)
  (:documentation "Add the groups of the state OTHER into STATE; MAPPING maps
OTHER's group ids to STATE's."))

(defgeneric agg-result (state gid)
  (:documentation "Final value of group GID."))

(defstruct (agg-state (:constructor nil))
  (capacity 0 :type fixnum))

(defun grow-array (array capacity initial)
  "Copy of ARRAY with room for CAPACITY elements, new ones INITIAL."
  (let ((new (make-array capacity :element-type (array-element-type array)
                                  :initial-element initial)))
    (replace new array)
    new))

(defun next-capacity (state groups)
  (max groups (* 2 (agg-state-capacity state)) 16))

;;; ------------------------------------------------------------------
;;; COUNT(*) and COUNT(x)

(defstruct (count-state (:include agg-state))
  (star nil)
  (counts (make-index-vector 0) :type index-vector))

(defmethod agg-reserve ((s count-state) groups)
  (when (> groups (agg-state-capacity s))
    (let ((c (next-capacity s groups)))
      (setf (count-state-counts s) (grow-array (count-state-counts s) c 0)
            (agg-state-capacity s) c))))

(defmethod agg-update ((s count-state) gids vec n)
  (declare (type index-vector gids) (type fixnum n))
  (let ((counts (count-state-counts s)))
    (declare (type index-vector counts))
    (if (or (count-state-star s)
            (and (not (simple-vector-p (vec-data vec))) (null (vec-validity vec))))
        (dotimes (i n) (incf (aref counts (aref gids i))))
        (let ((data (vec-data vec)) (validity (vec-validity vec)))
          (if (simple-vector-p data)
              (dotimes (i n)
                (unless (eq (svref data i) +null+) (incf (aref counts (aref gids i)))))
              (dotimes (i n)
                (unless (zerop (sbit validity i)) (incf (aref counts (aref gids i))))))))))

(defmethod agg-merge ((s count-state) other mapping)
  (let ((counts (count-state-counts s))
        (theirs (count-state-counts other)))
    (dotimes (g (length mapping))
      (incf (aref counts (aref mapping g)) (aref theirs g)))))

(defmethod agg-result ((s count-state) gid)
  (aref (count-state-counts s) gid))

;;; ------------------------------------------------------------------
;;; SUM and AVG

(defstruct (sum-state (:include agg-state))
  fn                                     ; :SUM or :AVG
  float-p
  (decimal-p nil)
  (divisor 1)                            ; AVG of DECIMAL: 10^scale
  (sums #() :type simple-vector)         ; exact integers or doubles, by group
  (counts (make-index-vector 0) :type index-vector)) ; non-NULL inputs, by group

(defmethod agg-reserve ((s sum-state) groups)
  (when (> groups (agg-state-capacity s))
    (let ((c (next-capacity s groups)))
      (setf (sum-state-sums s) (grow-array (sum-state-sums s) c (if (sum-state-float-p s) 0d0 0))
            (sum-state-counts s) (grow-array (sum-state-counts s) c 0)
            (agg-state-capacity s) c))))

(defmethod agg-update ((s sum-state) gids vec n)
  (declare (type index-vector gids) (type fixnum n))
  (let ((sums (sum-state-sums s))
        (counts (sum-state-counts s))
        (data (vec-data vec))
        (validity (vec-validity vec)))
    (declare (type simple-vector sums) (type index-vector counts))
    (etypecase data
      (i64-vector
       (do-valid-rows (i n validity)
         (let ((g (aref gids i)))
           (setf (svref sums g) (+ (the integer (svref sums g)) (aref data i)))
           (incf (aref counts g)))))
      (f64-vector
       (do-valid-rows (i n validity)
         (let ((g (aref gids i)))
           (setf (svref sums g) (+ (the double-float (svref sums g)) (aref data i)))
           (incf (aref counts g)))))
      (simple-vector
       ;; Only the NULL type reaches here (all values NULL).
       (dotimes (i n)
         (let ((v (svref data i)))
           (unless (eq v +null+)
             (let ((g (aref gids i)))
               (setf (svref sums g) (+ (svref sums g) v))
               (incf (aref counts g))))))))))

(defmethod agg-merge ((s sum-state) other mapping)
  (let ((sums (sum-state-sums s)) (counts (sum-state-counts s))
        (their-sums (sum-state-sums other)) (their-counts (sum-state-counts other)))
    (dotimes (g (length mapping))
      (let ((to (aref mapping g)))
        (setf (svref sums to) (+ (svref sums to) (svref their-sums g)))
        (incf (aref counts to) (aref their-counts g))))))

(defmethod agg-result ((s sum-state) gid)
  (let ((sum (svref (sum-state-sums s) gid))
        (n (aref (sum-state-counts s) gid)))
    (cond ((zerop n) +null+)
          ((eq (sum-state-fn s) :avg)
           (if (sum-state-float-p s)
               (check-finite (/ sum n))
               (values (rational-to-double (/ sum (* n (sum-state-divisor s)))))))
          ((sum-state-float-p s) (check-finite sum))
          ((sum-state-decimal-p s)
           (if (fits-precision-p sum +max-decimal-precision+)
               sum
               (overflow-error "DECIMAL SUM exceeds 18 digits")))
          (t (check-int64 sum)))))

;;; ------------------------------------------------------------------
;;; MIN and MAX

(defstruct (minmax-state (:include agg-state))
  (sign -1 :type fixnum)                 ; -1 MIN, 1 MAX
  (cmp nil :type function)
  (best #() :type simple-vector))

(defmethod agg-reserve ((s minmax-state) groups)
  (when (> groups (agg-state-capacity s))
    (let ((c (next-capacity s groups)))
      (setf (minmax-state-best s) (grow-array (minmax-state-best s) c +null+)
            (agg-state-capacity s) c))))

(defmethod agg-update ((s minmax-state) gids vec n)
  (declare (type index-vector gids) (type fixnum n))
  (let ((best (minmax-state-best s))
        (data (vec-data vec))
        (validity (vec-validity vec))
        (min-p (= (minmax-state-sign s) -1)))
    (declare (type simple-vector best))
    (macrolet ((typed (element-type)
                 `(let ((data data))
                    (declare (type (simple-array ,element-type (*)) data))
                    (if min-p
                        (do-valid-rows (i n validity)
                          (let* ((g (aref gids i)) (b (svref best g)) (v (aref data i)))
                            (when (or (eq b +null+) (< v (the ,(if (eq element-type 'double-float) 'double-float 'integer) b)))
                              (setf (svref best g) v))))
                        (do-valid-rows (i n validity)
                          (let* ((g (aref gids i)) (b (svref best g)) (v (aref data i)))
                            (when (or (eq b +null+) (> v (the ,(if (eq element-type 'double-float) 'double-float 'integer) b)))
                              (setf (svref best g) v))))))))
      (etypecase data
        (i64-vector (typed (signed-byte 64)))
        (f64-vector (typed double-float))
        (simple-vector
         (let ((cmp (minmax-state-cmp s))
               (sign (minmax-state-sign s)))
           (dotimes (i n)
             (let ((v (svref data i)))
               (unless (eq v +null+)
                 (let* ((g (aref gids i)) (b (svref best g)))
                   (when (or (eq b +null+) (= (the fixnum (funcall cmp v b)) sign))
                     (setf (svref best g) v))))))))))))

(defmethod agg-merge ((s minmax-state) other mapping)
  (let ((best (minmax-state-best s))
        (theirs (minmax-state-best other))
        (cmp (minmax-state-cmp s))
        (sign (minmax-state-sign s)))
    (dotimes (g (length mapping))
      (let ((v (svref theirs g))
            (to (aref mapping g)))
        (unless (eq v +null+)
          (let ((b (svref best to)))
            (when (or (eq b +null+) (= (the fixnum (funcall cmp v b)) sign))
              (setf (svref best to) v))))))))

(defmethod agg-result ((s minmax-state) gid)
  (svref (minmax-state-best s) gid))

;;; ------------------------------------------------------------------
;;; DISTINCT aggregates: the distinct values of each group, in order of
;;; first appearance, are fed to a row accumulator when the result is needed.

(defstruct (distinct-state (:include agg-state))
  (factory nil :type function)           ; row accumulator factory (aggregates.lisp)
  (seen #() :type simple-vector)         ; per group: EQUAL hash table or NIL
  (values #() :type simple-vector))      ; per group: list of values, newest first

(defmethod agg-reserve ((s distinct-state) groups)
  (when (> groups (agg-state-capacity s))
    (let ((c (next-capacity s groups)))
      (setf (distinct-state-seen s) (grow-array (distinct-state-seen s) c nil)
            (distinct-state-values s) (grow-array (distinct-state-values s) c nil)
            (agg-state-capacity s) c))))

(defun distinct-add (s g v)
  (let ((seen (or (svref (distinct-state-seen s) g)
                  (setf (svref (distinct-state-seen s) g) (make-hash-table :test 'equal))))
        (k (distinct-key v)))
    (unless (gethash k seen)
      (setf (gethash k seen) t)
      (push v (svref (distinct-state-values s) g)))))

(defmethod agg-update ((s distinct-state) gids vec n)
  (declare (type index-vector gids) (type fixnum n))
  (dotimes (i n)
    (let ((v (vec-ref vec i)))
      (unless (eq v +null+)
        (distinct-add s (aref gids i) v)))))

(defmethod agg-merge ((s distinct-state) other mapping)
  (dotimes (g (length mapping))
    (dolist (v (reverse (svref (distinct-state-values other) g)))
      (distinct-add s (aref mapping g) v))))

(defmethod agg-result ((s distinct-state) gid)
  (multiple-value-bind (step finish) (funcall (distinct-state-factory s))
    (declare (type function step finish))
    (dolist (v (reverse (svref (distinct-state-values s) gid)))
      (funcall step v))
    (funcall finish)))

;;; ------------------------------------------------------------------
;;; Construction

(defun make-agg-state (agg)
  "A fresh, empty state for the aggregate call AGG (a B-AGG)."
  (let* ((fn (b-agg-fn agg))
         (arg-type (if (b-agg-args agg) (bexpr-type (first (b-agg-args agg))) :int64))
         (float-p (eq (type-kind arg-type) :float64)))
    (cond
      ((and (b-agg-distinct agg) (not (member fn '(:min :max :count-star))))
       (make-distinct-state :factory (make-base-accumulator-factory fn arg-type)))
      (t
       (ecase fn
         (:count-star (make-count-state :star t))
         (:count (make-count-state))
         ((:sum :avg)
          (make-sum-state :fn fn :float-p float-p
                          :decimal-p (decimal-type-p arg-type)
                          :divisor (if (decimal-type-p arg-type) (pow10 (decimal-scale arg-type)) 1)))
         ((:min :max)
          (make-minmax-state :sign (if (eq fn :min) -1 1) :cmp (make-comparator arg-type))))))))

;;; ------------------------------------------------------------------
;;; Group states: key table + aggregate states

(defstruct (group-state (:constructor %make-group-state))
  (table nil)                            ; KEY-TABLE, or NIL without GROUP BY
  (aggs #() :type simple-vector)         ; of AGG-STATE
  (gids (make-index-vector +batch-size+) :type index-vector))

(defun make-group-state (key-kinds aggs)
  "Empty group state for keys of KEY-KINDS (a list of vector kinds) and the
aggregate calls AGGS."
  (let ((gs (%make-group-state :table (and key-kinds
                                           (make-key-table (length key-kinds) 16 key-kinds))
                               :aggs (map 'simple-vector #'make-agg-state aggs))))
    (unless (group-state-table gs)
      (fill (group-state-gids gs) 0)
      (loop for s across (group-state-aggs gs) do (agg-reserve s 1)))
    gs))

(defun group-state-count (gs)
  (let ((table (group-state-table gs)))
    (if table (key-table-count table) 1)))

(defun group-state-consume (gs key-vecs arg-vecs n)
  "Aggregate N rows given their key VECs and aggregate argument VECs."
  (declare (type fixnum n))
  (let ((gids (group-state-gids gs))
        (table (group-state-table gs)))
    (when (> n (length gids))
      (setf gids (make-index-vector n)
            (group-state-gids gs) gids)
      (unless table (fill gids 0)))
    (when table
      (key-table-map-batch table key-vecs n gids t))
    (let ((groups (group-state-count gs)))
      (loop for s across (group-state-aggs gs)
            for v in arg-vecs
            do (agg-reserve s groups)
               (agg-update s gids v n)))))

(defun group-state-merge (gs other)
  "Merge the partial group state OTHER into GS."
  (let* ((count (group-state-count other))
         (mapping (make-index-vector count))
         (table (group-state-table gs)))
    (if table
        (dotimes (g count)
          (setf (aref mapping g) (key-table-intern-group table (group-state-table other) g)))
        (fill mapping 0))
    (let ((groups (group-state-count gs)))
      (loop for s across (group-state-aggs gs)
            for o across (group-state-aggs other)
            do (agg-reserve s groups)
               (agg-merge s o mapping)))))

(defun group-state-batch (gs start end key-kinds agg-kinds)
  "Output batch of groups [START, END): key columns then aggregate results."
  (let* ((n (- end start))
         (table (group-state-table gs))
         (nkeys (length key-kinds))
         (columns (make-array (+ nkeys (length agg-kinds)))))
    (dotimes (k nkeys)
      (let ((k k))
        (setf (svref columns k)
              (build-vec (svref key-kinds k) n
                         (lambda (i) (key-table-key table k (+ start i)))))))
    (loop for s across (group-state-aggs gs)
          for j from nkeys
          for kind across agg-kinds
          do (let ((s s))
               (setf (svref columns j)
                     (build-vec kind n (lambda (i) (agg-result s (+ start i)))))))
    (make-batch n columns)))
