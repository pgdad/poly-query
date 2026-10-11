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
;;;;
;;;; With native kernels (`native: true`), AGG-UPDATE-NATIVE updates a state
;;;; from a whole batch with libpqkernels where a kernel applies:
;;;;   SUM/AVG of INT64/DECIMAL   pqk_sum_i64 (no GROUP BY) or pqk_group_sum_i64
;;;;   COUNT(x)                   pqk_bitmap_popcount of the validity (no GROUP BY)
;;;;   MIN/MAX of INT64-like      pqk_minmax_i64 (no GROUP BY)
;;;;   MIN/MAX of FLOAT64         pqk_minmax_f64 (no GROUP BY)
;;;; Kernel overflow flags are honoured exactly: a batch whose int64 sum
;;;; overflows is summed again exactly in Lisp. FLOAT64 sums stay in Lisp:
;;;; pqk_sum_f64 reassociates the additions, which could change the result.

(in-package #:polyquery)

(defgeneric agg-reserve (state groups)
  (:documentation "Make room for group ids below GROUPS."))

(defgeneric agg-update (state gids vec n)
  (:documentation "Accumulate rows [0, N) of the argument VEC (NIL for
COUNT(*)) into the groups GIDS."))

(defgeneric agg-merge (state other mapping)
  (:documentation "Add the groups of the state OTHER into STATE; MAPPING maps
OTHER's group ids to STATE's (-1: the group is merged elsewhere)."))

(defgeneric agg-result (state gid)
  (:documentation "Final value of group GID."))

(defgeneric agg-update-native (state gids gids32 vec n)
  (:documentation "Accumulate rows [0, N) of the argument VEC with the native
kernels, if they apply: GIDS are the rows' group ids (an INDEX-VECTOR) and
GIDS32 a function returning them as a U32-VECTOR, or both NIL when there is
no GROUP BY (every row in group 0). Returns true if the rows were consumed,
NIL to have AGG-UPDATE consume them.")
  (:method (state gids gids32 vec n)
    (declare (ignore state gids gids32 vec n))
    nil))

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

(defmethod agg-update-native ((s count-state) gids gids32 vec n)
  (declare (ignore gids32) (type fixnum n))
  (when (and (null gids) (not (count-state-star s)) (not (simple-vector-p (vec-data vec))))
    (let ((validity (vec-validity vec)))
      (incf (aref (count-state-counts s) 0) (if validity (native-popcount validity n) n))
      t)))

(defmethod agg-merge ((s count-state) other mapping)
  (let ((counts (count-state-counts s))
        (theirs (count-state-counts other)))
    (dotimes (g (length mapping))
      (let ((to (aref mapping g)))
        (when (>= to 0)
          (incf (aref counts to) (aref theirs g)))))))

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
  (counts (make-index-vector 0) :type index-vector) ; non-NULL inputs, by group
  ;; Accumulators of pqk_group_sum_i64 (allocated on first use), added to
  ;; SUMS / COUNTS for the result. They always hold exact values: a batch
  ;; whose native accumulation overflowed is undone and summed in SUMS.
  (native-sums nil :type (or null i64-vector))
  (native-counts nil :type (or null i64-vector)))

(defmethod agg-reserve ((s sum-state) groups)
  (when (> groups (agg-state-capacity s))
    (let ((c (next-capacity s groups)))
      (setf (sum-state-sums s) (grow-array (sum-state-sums s) c (if (sum-state-float-p s) 0d0 0))
            (sum-state-counts s) (grow-array (sum-state-counts s) c 0)
            (agg-state-capacity s) c)
      (when (sum-state-native-sums s)
        (setf (sum-state-native-sums s) (grow-array (sum-state-native-sums s) c 0)
              (sum-state-native-counts s) (grow-array (sum-state-native-counts s) c 0))))))

(defun sum-state-group (s g)
  "(values sum count) of group G."
  (let ((sum (svref (sum-state-sums s) g))
        (n (aref (sum-state-counts s) g))
        (native-sums (sum-state-native-sums s)))
    (if native-sums
        (values (+ sum (aref native-sums g)) (+ n (aref (sum-state-native-counts s) g)))
        (values sum n))))

(declaim (inline wrap-int64))
(defun wrap-int64 (v)
  "V modulo 2^64 as a signed 64-bit integer (two's-complement wrapping)."
  (let ((u (ldb (byte 64 0) v)))
    (if (logbitp 63 u) (- u (expt 2 64)) u)))

(defmethod agg-update-native ((s sum-state) gids gids32 vec n)
  (declare (type fixnum n))
  (let ((data (vec-data vec))
        (validity (vec-validity vec)))
    (when (typep data 'i64-vector)
      (cond
        ((null gids)
         ;; One group: the exact sum of the batch, or (on overflow) the batch
         ;; summed again with unbounded integers.
         (let ((sums (sum-state-sums s)))
           (setf (svref sums 0)
                 (+ (svref sums 0)
                    (multiple-value-bind (sum ok) (native-sum-i64 data validity n)
                      (if ok
                          sum
                          (let ((exact 0))
                            (declare (type integer exact))
                            (do-valid-rows (i n validity) (incf exact (aref data i)))
                            exact)))))
           (incf (aref (sum-state-counts s) 0) (if validity (native-popcount validity n) n))
           t))
        (t
         (unless (sum-state-native-sums s)
           (let ((c (agg-state-capacity s)))
             (setf (sum-state-native-sums s) (make-array c :element-type '(signed-byte 64) :initial-element 0)
                   (sum-state-native-counts s) (make-array c :element-type '(signed-byte 64) :initial-element 0))))
         (let* ((native-sums (sum-state-native-sums s))
                (status (native-group-sum-i64 (funcall (the function gids32)) data validity n
                                              native-sums (sum-state-native-counts s)
                                              (length native-sums))))
           (declare (type i64-vector native-sums) (type index-vector gids))
           (cond
             ((= status +pqk-ok+) t)
             ((= status +pqk-overflow+)
              ;; Some addition wrapped: undo the batch's (wrapping) additions,
              ;; which restores the previous exact native sums, and add the
              ;; batch exactly instead. The counts were updated correctly.
              (let ((sums (sum-state-sums s)))
                (do-valid-rows (i n validity)
                  (let ((g (aref gids i))
                        (v (aref data i)))
                    (setf (aref native-sums g) (wrap-int64 (- (aref native-sums g) v))
                          (svref sums g) (+ (svref sums g) v)))))
              t)
             (t nil))))))))

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
  (let ((sums (sum-state-sums s)) (counts (sum-state-counts s)))
    (dotimes (g (length mapping))
      (let ((to (aref mapping g)))
        (when (>= to 0)
          (multiple-value-bind (their-sum their-count) (sum-state-group other g)
            (setf (svref sums to) (+ (svref sums to) their-sum))
            (incf (aref counts to) their-count)))))))

(defmethod agg-result ((s sum-state) gid)
  (multiple-value-bind (sum n) (sum-state-group s gid)
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

(defmethod agg-update-native ((s minmax-state) gids gids32 vec n)
  (declare (ignore gids32) (type fixnum n))
  (unless gids
    (let ((data (vec-data vec))
          (validity (vec-validity vec))
          (min-p (= (minmax-state-sign s) -1))
          (best (minmax-state-best s)))
      (flet ((offer (count lo hi)
               (when (plusp count)
                 (let ((v (if min-p lo hi))
                       (b (svref best 0)))
                   (when (or (eq b +null+) (if min-p (< v b) (> v b)))
                     (setf (svref best 0) v))))
               t))
        (typecase data
          (i64-vector
           (multiple-value-call #'offer (native-minmax-i64 data validity n)))
          (f64-vector
           ;; Like the Lisp loop, the kernel returns the first of equal
           ;; extremes in row order (0.0 and -0.0 included).
           (multiple-value-call #'offer (native-minmax-f64 data validity n)))
          (t nil))))))

(defmethod agg-merge ((s minmax-state) other mapping)
  (let ((best (minmax-state-best s))
        (theirs (minmax-state-best other))
        (cmp (minmax-state-cmp s))
        (sign (minmax-state-sign s)))
    (dotimes (g (length mapping))
      (let ((v (svref theirs g))
            (to (aref mapping g)))
        (unless (or (eq v +null+) (< to 0))
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
    (when (>= (aref mapping g) 0)
      (dolist (v (reverse (svref (distinct-state-values other) g)))
        (distinct-add s (aref mapping g) v)))))

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
  (charged 0 :type fixnum)               ; groups charged to the memory budget
  (aggs #() :type simple-vector)         ; of AGG-STATE
  (gids (make-index-vector +batch-size+) :type index-vector)
  (native nil)                           ; update aggregates with native kernels
  (gids32 nil :type (or null u32-vector)) ; GIDS as 32-bit ids for the kernels
  ;; Partial states of parallel aggregation record each group's first input
  ;; position, so the merged groups can be emitted in serial order.
  (positions nil :type (or null index-vector)))

(defun make-group-state (key-kinds aggs &optional track-positions native)
  "Empty group state for keys of KEY-KINDS (a list of vector kinds) and the
aggregate calls AGGS; TRACK-POSITIONS records first input positions, NATIVE
uses the native kernels."
  (let ((gs (%make-group-state :native native
                               :table (and key-kinds
                                           (make-key-table (length key-kinds) 16 key-kinds native))
                               :aggs (map 'simple-vector #'make-agg-state aggs)
                               :positions (and track-positions key-kinds
                                               (make-array 16 :element-type 'fixnum
                                                              :initial-element most-positive-fixnum)))))
    (unless (group-state-table gs)
      (fill (group-state-gids gs) 0)
      (loop for s across (group-state-aggs gs) do (agg-reserve s 1)))
    gs))

(defun group-state-count (gs)
  (let ((table (group-state-table gs)))
    (if table (key-table-count table) 1)))

(defun group-state-reserve-positions (gs groups)
  (let ((positions (group-state-positions gs)))
    (when (and positions (< (length positions) groups))
      (setf (group-state-positions gs)
            (grow-array positions (max groups (* 2 (length positions))) most-positive-fixnum)))))

(defun group-state-consume (gs key-vecs arg-vecs n &optional (base 0))
  "Aggregate N rows given their key VECs and aggregate argument VECs; BASE is
the input position of the first row (when positions are tracked)."
  (declare (type fixnum n base))
  (let ((gids (group-state-gids gs))
        (table (group-state-table gs)))
    (declare (type index-vector gids))
    (when (> n (length gids))
      (setf gids (make-index-vector n)
            (group-state-gids gs) gids)
      (unless table (fill gids 0)))
    (when table
      (let ((before (key-table-count table)))
        (key-table-map-batch table key-vecs n gids t)
        (when (and (group-state-positions gs) (> (key-table-count table) before))
          (group-state-reserve-positions gs (key-table-count table))
          (let ((positions (group-state-positions gs)))
            (dotimes (i n)
              (let ((g (aref gids i)))
                (when (and (>= g before) (= (aref positions g) most-positive-fixnum))
                  (setf (aref positions g) (+ base i)))))))))
    (let ((groups (group-state-count gs))
          (gids32 nil))
      (flet ((gids32 ()
               ;; The group ids as 32-bit integers, converted once per batch.
               (or gids32
                   (let ((out (group-state-gids32 gs)))
                     (when (or (null out) (< (length out) n))
                       (setf out (make-array (max n +batch-size+) :element-type '(unsigned-byte 32))
                             (group-state-gids32 gs) out))
                     (let ((out out))
                       (declare (type u32-vector out))
                       (dotimes (i n) (setf (aref out i) (the (unsigned-byte 32) (aref gids i)))))
                     (setf gids32 out)))))
        (loop for s across (group-state-aggs gs)
              for v in arg-vecs
              do (agg-reserve s groups)
                 (unless (and (group-state-native gs) v
                              (if table
                                  (agg-update-native s gids #'gids32 v n)
                                  (agg-update-native s nil nil v n)))
                   (agg-update s gids v n)))))))

(defun group-state-partitions (gs partitions)
  "Vector of PARTITIONS index vectors: the group ids of GS whose key hash is
the partition number modulo PARTITIONS."
  (let* ((count (group-state-count gs))
         (table (group-state-table gs))
         (parts (make-array count :element-type 'fixnum))
         (sizes (make-array partitions :element-type 'fixnum :initial-element 0)))
    (dotimes (g count)
      (let ((p (mod (key-table-group-hash table g) partitions)))
        (setf (aref parts g) p)
        (incf (aref sizes p))))
    (let ((out (map 'simple-vector #'make-index-vector sizes)))
      (fill sizes 0)
      (dotimes (g count out)
        (let ((p (aref parts g)))
          (setf (aref (the index-vector (svref out p)) (aref sizes p)) g)
          (incf (aref sizes p)))))))

(defun group-state-merge (gs other &optional only)
  "Merge the partial group state OTHER into GS; when ONLY (an index vector of
OTHER's group ids) is given, just those groups."
  (let* ((count (group-state-count other))
         (mapping (make-index-vector count))
         (table (group-state-table gs))
         (other-table (group-state-table other)))
    (cond ((null table) (fill mapping 0))
          (only
           (fill mapping -1)
           (loop for g across (the index-vector only)
                 do (setf (aref mapping g) (key-table-intern-group table other-table g))))
          (t
           (dotimes (g count)
             (setf (aref mapping g) (key-table-intern-group table other-table g)))))
    (when (and (group-state-positions gs) (group-state-positions other))
      (group-state-reserve-positions gs (group-state-count gs))
      (let ((positions (group-state-positions gs))
            (theirs (group-state-positions other)))
        (dotimes (g count)
          (let ((to (aref mapping g)))
            (when (>= to 0)
              (setf (aref positions to) (min (aref positions to) (aref theirs g))))))))
    (let ((groups (group-state-count gs)))
      (loop for s across (group-state-aggs gs)
            for o across (group-state-aggs other)
            do (agg-reserve s groups)
               (agg-merge s o mapping)))))

(defun radix-sort-by-keys (keys)
  "Permutation of [0, n) ordering the non-negative fixnum KEYS ascending
(LSD radix sort, stable)."
  (declare (type index-vector keys))
  (let* ((n (length keys))
         (perm (identity-index-vector n))
         (tmp (make-index-vector n))
         (counts (make-array 2049 :element-type 'fixnum))
         (max-key (if (zerop n) 0 (reduce #'max keys))))
    (declare (type index-vector perm tmp) (type fixnum max-key))
    (loop for shift of-type fixnum from 0 by 11
          while (< shift (integer-length max-key))
          do (fill counts 0)
             (dotimes (i n)
               (incf (aref counts (1+ (ldb (byte 11 shift) (aref keys (aref perm i)))))))
             (loop for d from 1 to 2048
                   do (incf (aref counts d) (aref counts (1- d))))
             (dotimes (i n)
               (let* ((e (aref perm i))
                      (d (ldb (byte 11 shift) (aref keys e))))
                 (setf (aref tmp (aref counts d)) e)
                 (incf (aref counts d))))
             (rotatef perm tmp))
    perm))

(defun groups-in-position-order (states)
  "Vectors (states gids) listing the groups of the merged group STATES in
order of their first input position."
  (let* ((n (reduce #'+ states :key #'group-state-count))
         (keys (make-index-vector n))
         (owners (make-array n))
         (gids (make-index-vector n))
         (k 0))
    (declare (type fixnum k))
    (loop for gs across states
          do (let ((positions (group-state-positions gs)))
               (dotimes (g (group-state-count gs))
                 (setf (aref keys k) (if positions (aref positions g) g)
                       (svref owners k) gs
                       (aref gids k) g)
                 (incf k))))
    (let ((perm (radix-sort-by-keys keys))
          (sorted-owners (make-array n))
          (sorted-gids (make-index-vector n)))
      (dotimes (i n)
        (let ((e (aref perm i)))
          (setf (svref sorted-owners i) (svref owners e)
                (aref sorted-gids i) (aref gids e))))
      (values sorted-owners sorted-gids))))

(defun group-entries-batch (states gids start end key-kinds agg-kinds)
  "Output batch of the groups (STATES[i], GIDS[i]) for i in [START, END)."
  (let* ((n (- end start))
         (nkeys (length key-kinds))
         (columns (make-array (+ nkeys (length agg-kinds)))))
    (dotimes (k nkeys)
      (let ((k k))
        (setf (svref columns k)
              (build-vec (svref key-kinds k) n
                         (lambda (i)
                           (key-table-key (group-state-table (svref states (+ start i))) k
                                          (aref gids (+ start i))))))))
    (dotimes (j (length agg-kinds))
      (let ((j j))
        (setf (svref columns (+ nkeys j))
              (build-vec (svref agg-kinds j) n
                         (lambda (i)
                           (agg-result (svref (group-state-aggs (svref states (+ start i))) j)
                                       (aref gids (+ start i))))))))
    (make-batch n columns)))

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
