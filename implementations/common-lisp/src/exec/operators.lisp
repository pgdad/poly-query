;;;; operators.lisp — row-at-a-time (Volcano) physical operators.
;;;;
;;;; COMPILE-PLAN turns a physical plan into an *opener*: a function of no
;;;; arguments that returns a fresh iterator. Expressions are compiled once,
;;;; when the plan is compiled; an opener may be called many times (e.g. for
;;;; a correlated subquery). An iterator is a function of no arguments that
;;;; returns the next row (a SIMPLE-VECTOR) or NIL at the end.

(in-package #:polyquery)

(defconstant +interrupt-check-interval+ 4096
  "Rows processed between checks for timeout/cancellation.")

(defgeneric compile-operator (node)
  (:documentation "Return the opener implementing physical plan NODE."))

(defun compile-plan (node &key count-only)
  "Row opener for the physical plan NODE, on the executor selected by the
statement's execution settings. COUNT-ONLY: the consumer only counts the
rows, so the vectorized executor may return placeholder rows."
  (if (vectorized-execution-p)
      (compile-vectorized-plan node :count-only count-only)
      (compile-operator node)))

(defmacro counting-interrupts ((counter) &body body)
  "Run BODY, checking for timeout/cancellation every few thousand calls."
  `(progn
     (when (zerop (logand (incf ,counter) 4095))
       (check-interrupts))
     ,@body))

(defun drain (iterator)
  "Collect all remaining rows of ITERATOR into a simple-vector, charging memory."
  (declare (type function iterator))
  (let ((acc (make-array 64 :adjustable t :fill-pointer 0)))
    (loop for row = (funcall iterator)
          while row
          do (when (zerop (mod (fill-pointer acc) +interrupt-check-interval+))
               (check-interrupts)
               (charge-memory (* +interrupt-check-interval+ (row-footprint (length row)))))
             (vector-push-extend row acc))
    (coerce acc 'simple-vector)))

(defun evaluate-limit-expr (e what)
  "Value of a constant LIMIT/OFFSET expression; NIL for absent or NULL."
  (when e
    (let ((v (evaluate-constant e)))
      (cond ((null-value-p v) nil)
            ((minusp v) (invalid-argument-error "~A must not be negative" what))
            (t v)))))

;;; ------------------------------------------------------------------
;;; Leaves

(defmethod compile-operator ((node pp-values))
  (lambda ()
    (let ((done nil))
      (lambda ()
        (unless done
          (setf done t)
          (vector))))))

(defun segment-row-builder (segment column-indexes)
  "Function (local-index) -> fresh row of COLUMN-INDEXES from SEGMENT."
  (declare (type simple-vector column-indexes))
  (let ((width (length column-indexes)))
    (declare (type fixnum width))
    (if (segment-rows segment)
        (let ((rows (segment-rows segment)))
          (declare (type simple-vector rows))
          (lambda (i)
            (declare (type fixnum i))
            (let ((src (svref rows i))
                  (row (make-array width)))
              (declare (type simple-vector src))
              (dotimes (k width row)
                (setf (svref row k) (svref src (svref column-indexes k)))))))
        (let ((readers (map 'simple-vector (lambda (k) (segment-column-reader segment k))
                            column-indexes)))
          (lambda (i)
            (declare (type fixnum i))
            (let ((row (make-array width)))
              (dotimes (k width row)
                (setf (svref row k) (funcall (the function (svref readers k)) i)))))))))

;;; Full scans walk the segments in order, skipping those whose statistics
;;; exclude a pushed-down predicate; only the pruned columns are read.
(defmethod compile-operator ((node pp-table-scan))
  (let* ((table (pp-table-scan-table node))
         (segments (table-segments table))
         (column-indexes (pp-table-scan-column-indexes node))
         (skip-p (compile-skip-test table (pp-table-scan-skips node))))
    (lambda ()
      (let ((s -1) (i 0) (n 0) (build nil) (count 0))
        (declare (type fixnum s i n count))
        (lambda ()
          (loop
            (when (< i n)
              (when (zerop (logand (incf count) 4095))
                (check-interrupts))
              (return (prog1 (funcall (the function build) i) (incf i))))
            (incf s)
            (when (>= s (length segments)) (return nil))
            (let ((seg (svref segments s)))
              (setf i 0 n 0)
              (unless (or (zerop (segment-count seg)) (and skip-p (funcall skip-p seg)))
                (setf build (segment-row-builder seg column-indexes)
                      n (segment-count seg))))))))))

;;; Index scans fetch the rows selected by an index lookup, in row-id order.
(defmethod compile-operator ((node pp-index-scan))
  (let* ((table (pp-index-scan-table node))
         (access (pp-index-scan-access node))
         (fetch (table-row-fetcher table (pp-index-scan-column-indexes node))))
    (declare (type function fetch))
    (lambda ()
      (let ((ids nil) (i 0))
        (declare (type fixnum i))
        (lambda ()
          (unless ids
            (setf ids (index-access-row-ids access))
            (charge-memory (* 8 (length ids))))
          (when (< i (length (the simple-vector ids)))
            (when (zerop (logand i 4095)) (check-interrupts))
            (prog1 (funcall fetch (svref ids i)) (incf i))))))))

;;; Equality lookups for correlated subqueries: the table is hashed on the
;;; key expressions once (lazily) and every execution probes it with the
;;; current parameter values.
(defmethod compile-operator ((node pp-lookup-scan))
  (let* ((table (pp-lookup-scan-table node))
         (fetch-columns (pp-lookup-scan-column-indexes node))
         (width (length fetch-columns))
         (keys (pp-lookup-scan-key-exprs node))
         (probes (pp-lookup-scan-probe-exprs node))
         (row-key (make-key-function keys probes))
         (probe-key (make-key-function probes keys))
         (residual (and (pp-lookup-scan-residual node)
                        (compile-bexpr (pp-lookup-scan-residual node))))
         (index nil))
    (declare (type fixnum width) (type function row-key probe-key))
    (flet ((build-index ()
             (let ((h (make-hash-table :test 'equal))
                   (scan (funcall (the function
                                       (compile-operator
                                        (make-pp-table-scan :table table
                                                            :column-indexes fetch-columns))))))
               (declare (type function scan))
               (loop for row = (funcall scan)
                     for i of-type fixnum from 0
                     while row
                     do (when (zerop (logand i 4095))
                          (charge-memory (* 4096 (row-footprint (+ 4 width)))))
                        (let ((key (funcall row-key row)))
                          (when key (push row (gethash key h)))))
               (maphash (lambda (k rows) (setf (gethash k h) (nreverse rows))) h)
               h)))
      (lambda ()
        (unless index (setf index (build-index)))
        (let* ((key (funcall probe-key (vector)))
               (candidates (and key (gethash key index))))
          (lambda ()
            (loop
              (when (null candidates) (return nil))
              (let ((row (pop candidates)))
                (when (or (null residual) (eq (funcall (the function residual) row) t))
                  (return row))))))))))

;;; ------------------------------------------------------------------
;;; Filter and projection

(defun never-true-p (predicate)
  "True if PREDICATE is a FALSE or NULL literal: the filter passes no row."
  (and (b-literal-p predicate) (not (eq (b-literal-value predicate) t))))

(defmethod compile-operator ((node pp-filter))
  (if (never-true-p (pp-filter-predicate node))
      (lambda () (lambda () nil))
      (compile-row-filter node)))

(defun compile-row-filter (node)
  (let ((open-child (compile-operator (pnode-child node)))
        (pred (compile-bexpr (pp-filter-predicate node))))
    (declare (type function open-child pred))
    (lambda ()
      (let ((child (funcall open-child))
            (count 0))
        (declare (type function child) (type fixnum count))
        (lambda ()
          (loop
            (let ((row (funcall child)))
              (when (null row) (return nil))
              (counting-interrupts (count)
                (when (eq (funcall pred row) t)
                  (return row))))))))))

(defmethod compile-operator ((node pp-project))
  (let ((open-child (compile-operator (pnode-child node)))
        (fns (coerce (mapcar #'compile-bexpr (pp-project-exprs node)) 'simple-vector)))
    (declare (type function open-child))
    (lambda ()
      (let ((child (funcall open-child)))
        (declare (type function child))
        (lambda ()
          (let ((row (funcall child)))
            (when row
              (let ((out (make-array (length fns))))
                (dotimes (k (length fns) out)
                  (setf (svref out k) (funcall (the function (svref fns k)) row)))))))))))

;;; ------------------------------------------------------------------
;;; Joins (semantics.md §7)

(defun concat-rows (left right)
  (declare (type simple-vector left right))
  (let ((out (make-array (+ (length left) (length right)))))
    (replace out left)
    (replace out right :start1 (length left))
    out))

(defstruct (row-cell (:constructor make-row-cell ()))
  "Row count shared by the parallel copies of one join operator."
  (count 0 :type sb-ext:word))

(defun join-row-counter (&optional cell)
  "Function to call with the number of rows a join produced (default 1);
enforces --max-join-rows (counted in CELL when the operator runs in several
parallel copies) and checks for interrupts every few thousand rows."
  (let ((count 0)
        (limit (and *query-context* (query-context-max-join-rows *query-context*))))
    (declare (type fixnum count))
    (lambda (&optional (n 1))
      (declare (type fixnum n))
      (let ((before count))
        (incf count n)
        (when limit
          (when (> (if cell (+ (sb-ext:atomic-incf (row-cell-count cell) n) n) count) limit)
            (resource-limit-error "join produced more than ~D rows (--max-join-rows)" limit)))
        (unless (= (ash before -12) (ash count -12))
          (check-interrupts))))))

(defun make-join-iterator (kind left matches-fn right-width)
  "Common driver for joins. MATCHES-FN maps a left row to a generator: a
function returning its successive matching right rows, then NIL. LEFT joins
pad unmatched left rows with NULLs."
  (declare (type function left matches-fn))
  (let ((counter (join-row-counter))
        (current nil)
        (next-match nil)
        (matched nil)
        (padding (make-array right-width :initial-element +null+)))
    (declare (type function counter))
    (lambda ()
      (loop
        (when current
          (let ((r (funcall (the function next-match))))
            (cond (r (setf matched t)
                     (funcall counter)
                     (return (concat-rows current r)))
                  ((and (eq kind :left) (not matched))
                   (let ((row current))
                     (setf current nil)
                     (funcall counter)
                     (return (concat-rows row padding))))
                  (t (setf current nil)))))
        (let ((row (funcall left)))
          (unless row (return nil))
          (setf current row
                matched nil
                next-match (funcall matches-fn row)))))))

(defmethod compile-operator ((node pp-nested-loop-join))
  (destructuring-bind (left right) (pnode-children node)
    (let ((open-left (compile-operator left))
          (open-right (compile-operator right))
          (cond (and (pp-nested-loop-join-condition node)
                     (compile-bexpr (pp-nested-loop-join-condition node))))
          (kind (pp-nested-loop-join-kind node))
          (right-width (length (pnode-columns right)))
          (invariant (plan-invariant-p right))
          (cached nil))
      (declare (type function open-left open-right))
      (lambda ()
        (let ((rights (and invariant cached))
              (probes 0))
          (declare (type fixnum probes))
          (make-join-iterator
           kind (funcall open-left)
           (lambda (lrow)
             (unless rights
               (setf rights (drain (funcall open-right)))
               (when invariant (setf cached rights)))
             (let ((i 0) (n (length rights)))
               (declare (type fixnum i n))
               (lambda ()
                 (loop
                   (when (>= i n) (return nil))
                   (let ((r (svref rights i)))
                     (incf i)
                     (when (zerop (logand (incf probes) 4095)) (check-interrupts))
                     (when (or (null cond)
                               (eq (funcall (the function cond) (concat-rows lrow r)) t))
                       (return r)))))))
           right-width))))))

(defun make-key-function (exprs other-exprs)
  "Function computing the hash key of a row for join keys EXPRS (compared with
OTHER-EXPRS of the other side), or NIL when a key value is NULL."
  (let ((fns (mapcar #'compile-bexpr exprs))
        (norms (mapcar (lambda (a b) (hash-key-normalizer (bexpr-type a) (bexpr-type b)))
                       exprs other-exprs)))
    (if (= (length fns) 1)
        (let ((f (first fns)) (norm (first norms)))
          (declare (type function f norm))
          (lambda (row)
            (let ((v (funcall f row)))
              (if (null-value-p v) nil (list (funcall norm v))))))
        (lambda (row)
          (loop for f in fns
                for norm in norms
                for v = (funcall (the function f) row)
                when (null-value-p v) return nil
                collect (funcall (the function norm) v))))))

(defun build-hash-table (iterator key-fn)
  "Hash the rows of ITERATOR by KEY-FN (rows with a NULL key are dropped);
each bucket keeps its rows in input order."
  (declare (type function iterator key-fn))
  (let ((h (make-hash-table :test 'equal))
        (n 0))
    (declare (type fixnum n))
    (loop for row = (funcall iterator)
          while row
          do (when (zerop (logand (incf n) 4095))
               (check-interrupts)
               (charge-memory (* 4096 (row-footprint (+ 4 (length row))))))
             (let ((k (funcall key-fn row)))
               (when k (push row (gethash k h)))))
    (maphash (lambda (k rows) (setf (gethash k h) (nreverse rows))) h)
    h))

(defmethod compile-operator ((node pp-hash-join))
  (if (eq (pp-hash-join-build node) :left)
      (compile-left-build-hash-join node)
      (compile-right-build-hash-join node)))

(defun compile-left-build-hash-join (node)
  "Inner hash join that hashes the LEFT input and probes it with right rows."
  (destructuring-bind (left right) (pnode-children node)
    (let* ((open-left (compile-operator left))
           (open-right (compile-operator right))
           (lkeys (pp-hash-join-left-keys node))
           (rkeys (pp-hash-join-right-keys node))
           (left-key (make-key-function lkeys rkeys))
           (right-key (make-key-function rkeys lkeys))
           (residual (and (pp-hash-join-residual node) (compile-bexpr (pp-hash-join-residual node))))
           (invariant (plan-invariant-p left))
           (cached nil))
      (declare (type function open-left open-right left-key right-key))
      (lambda ()
        (let ((table (and invariant cached))
              (probe nil)
              (current nil)
              (candidates '())
              (counter (join-row-counter)))
          (declare (type function counter))
          (lambda ()
            (block emit
              (unless table
                (setf table (build-hash-table (funcall open-left) left-key))
                (when invariant (setf cached table)))
              (unless probe
                (setf probe (funcall open-right)))
              (loop
                ;; Emit the pending matches of the current right row ...
                (loop while candidates
                      do (let ((row (concat-rows (pop candidates) current)))
                           (when (or (null residual) (eq (funcall (the function residual) row) t))
                             (funcall counter)
                             (return-from emit row))))
                ;; ... then advance to the next right row.
                (let ((r (funcall (the function probe))))
                  (unless r (return-from emit nil))
                  (let ((k (funcall right-key r)))
                    (setf current r
                          candidates (and k (gethash k table)))))))))))))

(defun compile-right-build-hash-join (node)
  "Hash join that hashes the RIGHT input (INNER or LEFT) and streams the left."
  (destructuring-bind (left right) (pnode-children node)
    (let* ((open-left (compile-operator left))
           (open-right (compile-operator right))
           (lkeys (pp-hash-join-left-keys node))
           (rkeys (pp-hash-join-right-keys node))
           (left-key (make-key-function lkeys rkeys))
           (right-key (make-key-function rkeys lkeys))
           (residual (and (pp-hash-join-residual node) (compile-bexpr (pp-hash-join-residual node))))
           (kind (pp-hash-join-kind node))
           (right-width (length (pnode-columns right)))
           (invariant (plan-invariant-p right))
           (cached nil))
      (declare (type function open-left open-right left-key right-key))
      (lambda ()
        (let ((table (and invariant cached))
              (probes 0))
          (declare (type fixnum probes))
          (flet ((build () (build-hash-table (funcall open-right) right-key)))
            (make-join-iterator
             kind (funcall open-left)
             (lambda (lrow)
               (unless table
                 (setf table (build))
                 (when invariant (setf cached table)))
               (let* ((k (funcall left-key lrow))
                      (candidates (and k (gethash k table))))
                 (lambda ()
                   (loop
                     (when (null candidates) (return nil))
                     (let ((r (pop candidates)))
                       (when (zerop (logand (incf probes) 4095)) (check-interrupts))
                       (when (or (null residual)
                                 (eq (funcall (the function residual) (concat-rows lrow r)) t))
                         (return r)))))))
             right-width)))))))

;;; Sort-merge joins: both inputs are materialized and sorted (stably) on
;;; their normalized join keys; the left input is then merged with the
;;; groups of equal right keys. Rows with a NULL key never match.

(defun compare-key-values (a b)
  "Total order (-1/0/1) on normalized join-key values of one key column:
numbers, strings (code point order) or booleans; equal keys compare 0."
  (cond ((realp a) (cond ((< a b) -1) ((> a b) 1) (t 0)))
        ((stringp a) (cond ((string< a b) -1) ((string= a b) 0) (t 1)))
        ((eq a b) 0)
        ((null a) -1)
        (t 1)))

(defun compare-join-keys (a b)
  "Lexicographic order on key lists produced by MAKE-KEY-FUNCTION."
  (loop for x in a
        for y in b
        for c of-type fixnum = (compare-key-values x y)
        unless (zerop c) return c
        finally (return 0)))

(defun sorted-keyed-rows (rows key-fn &key keep-null-keys)
  "Vector of (key . row) for ROWS sorted stably by key; rows with a NULL key
are dropped, or (KEEP-NULL-KEYS) placed at the end with key NIL."
  (declare (type simple-vector rows) (type function key-fn))
  (let ((keyed '()) (null-keyed '()))
    (loop for row across rows
          for k = (funcall key-fn row)
          do (cond (k (push (cons k row) keyed))
                   (keep-null-keys (push (cons nil row) null-keyed))))
    (concatenate 'simple-vector
                 (stable-sort (nreverse keyed)
                              (lambda (a b) (minusp (compare-join-keys (car a) (car b)))))
                 (nreverse null-keyed))))

(defmethod compile-operator ((node pp-merge-join))
  (destructuring-bind (left right) (pnode-children node)
    (let* ((open-left (compile-operator left))
           (open-right (compile-operator right))
           (lkeys (pp-merge-join-left-keys node))
           (rkeys (pp-merge-join-right-keys node))
           (left-key (make-key-function lkeys rkeys))
           (right-key (make-key-function rkeys lkeys))
           (residual (and (pp-merge-join-residual node)
                          (compile-bexpr (pp-merge-join-residual node))))
           (kind (pp-merge-join-kind node))
           (right-width (length (pnode-columns right)))
           (invariant (plan-invariant-p right))
           (cached nil))
      (declare (type function open-left open-right))
      (lambda ()
        (let ((lefts (sorted-keyed-rows (drain (funcall open-left)) left-key
                                        :keep-null-keys (eq kind :left)))
              (rights (or (and invariant cached)
                          (sorted-keyed-rows (drain (funcall open-right)) right-key)))
              (li 0) (rpos 0) (current-key nil) (probes 0))
          (declare (type simple-vector lefts rights) (type fixnum li rpos probes))
          (when invariant (setf cached rights))
          (make-join-iterator
           kind
           (lambda ()
             (when (< li (length lefts))
               (let ((entry (svref lefts li)))
                 (incf li)
                 (setf current-key (car entry))
                 (cdr entry))))
           (lambda (lrow)
             (if (null current-key)
                 (lambda () nil)
                 (let ((key current-key))
                   ;; Advance to the first right key >= KEY (left keys ascend).
                   (loop while (and (< rpos (length rights))
                                    (minusp (compare-join-keys (car (svref rights rpos)) key)))
                         do (incf rpos))
                   (let ((j rpos))
                     (declare (type fixnum j))
                     (lambda ()
                       (loop
                         (when (or (>= j (length rights))
                                   (/= 0 (compare-join-keys (car (svref rights j)) key)))
                           (return nil))
                         (let ((r (cdr (svref rights j))))
                           (incf j)
                           (when (zerop (logand (incf probes) 4095)) (check-interrupts))
                           (when (or (null residual)
                                     (eq (funcall (the function residual) (concat-rows lrow r)) t))
                             (return r)))))))))
           right-width))))))

;;; ------------------------------------------------------------------
;;; Aggregation (semantics.md §5)

(defun group-key-normalizer (type)
  "Map a value of TYPE to a key under which equal values collide (-0.0 = 0.0)."
  (if (eq (type-kind type) :float64)
      (lambda (v) (if (and (floatp v) (zerop v)) 0d0 v))
      nil))

(defun make-row-key-function (types)
  "Function computing an EQUAL-hashable key for rows whose values have TYPES."
  (let ((norms (mapcar #'group-key-normalizer types)))
    (if (notany #'identity norms)
        (lambda (values) (coerce values 'list))
        (lambda (values)
          (loop for v across values
                for norm in norms
                collect (if norm (funcall (the function norm) v) v))))))

(defmethod compile-operator ((node pp-hash-aggregate))
  (let* ((open-child (compile-operator (pnode-child node)))
         (keys (pp-hash-aggregate-group-by node))
         (aggs (pp-hash-aggregate-aggregates node))
         (nkeys (length keys))
         (naggs (length aggs))
         (key-fns (coerce (mapcar #'compile-bexpr keys) 'simple-vector))
         (row-key (make-row-key-function (mapcar #'bexpr-type keys)))
         (arg-fns (map 'simple-vector
                       (lambda (a) (if (b-agg-args a)
                                       (compile-bexpr (first (b-agg-args a)))
                                       (constantly t)))
                       aggs))
         (factories (map 'simple-vector #'make-accumulator-factory aggs)))
    (declare (type function open-child row-key))
    (labels ((new-group (key-values)
               ;; A group: (key-values steps finishers)
               (let ((steps (make-array naggs)) (finishers (make-array naggs)))
                 (dotimes (k naggs)
                   (multiple-value-bind (step finish) (funcall (the function (svref factories k)))
                     (setf (svref steps k) step (svref finishers k) finish)))
                 (vector key-values steps finishers)))
             (feed (group row)
               (let ((steps (svref group 1)))
                 (dotimes (k naggs)
                   (funcall (the function (svref steps k))
                            (funcall (the function (svref arg-fns k)) row)))))
             (finish (group)
               (let ((out (make-array (+ nkeys naggs)))
                     (key-values (svref group 0))
                     (finishers (svref group 2)))
                 (replace out key-values)
                 (dotimes (k naggs out)
                   (setf (svref out (+ nkeys k)) (funcall (the function (svref finishers k))))))))
      (lambda ()
        (let ((groups nil) (started nil))
          (lambda ()
            (unless started
              (setf started t)
              (let ((child (funcall open-child))
                    (count 0))
                (declare (type function child) (type fixnum count))
                (if (zerop nkeys)
                    ;; Whole-input aggregation: exactly one row, even on empty input.
                    (let ((g (new-group (vector))))
                      (loop for row = (funcall child)
                            while row
                            do (counting-interrupts (count) (feed g row)))
                      (setf groups (list g)))
                    (let ((table (make-hash-table :test 'equal))
                          (order '()))
                      (loop for row = (funcall child)
                            while row
                            do (counting-interrupts (count)
                                 (let* ((key-values (make-array nkeys)))
                                   (dotimes (k nkeys)
                                     (setf (svref key-values k)
                                           (funcall (the function (svref key-fns k)) row)))
                                   (let* ((key (funcall row-key key-values))
                                          (g (gethash key table)))
                                     (unless g
                                       (setf g (new-group key-values)
                                             (gethash key table) g)
                                       (push g order)
                                       (when (zerop (logand (hash-table-count table) 1023))
                                         (charge-memory (* 1024 (row-footprint (* 4 (+ nkeys naggs)))))))
                                     (feed g row)))))
                      (setf groups (nreverse order))))))
            (when groups
              (finish (pop groups)))))))))

(defmethod compile-operator ((node pp-hash-distinct))
  (let* ((open-child (compile-operator (pnode-child node)))
         (row-key (make-row-key-function
                   (mapcar #'column-def-type (pnode-columns (pnode-child node))))))
    (declare (type function open-child row-key))
    (lambda ()
      (let ((child (funcall open-child))
            (seen (make-hash-table :test 'equal)))
        (declare (type function child))
        (lambda ()
          (loop
            (let ((row (funcall child)))
              (unless row (return nil))
              (let ((key (funcall row-key row)))
                (unless (gethash key seen)
                  (setf (gethash key seen) t)
                  (when (zerop (logand (hash-table-count seen) 1023))
                    (check-interrupts)
                    (charge-memory (* 1024 (row-footprint (* 2 (length row))))))
                  (return row))))))))))

;;; ------------------------------------------------------------------
;;; Sorting and limits

(defun make-row-comparator (keys)
  "Lexicographic row comparator (a b) -> T if A sorts strictly before B."
  (let ((key-fns (loop for (pos type desc nulls-first) in keys
                       collect (cons pos (make-sort-key-comparator type desc nulls-first)))))
    (lambda (a b)
      (loop for (pos . cmp) in key-fns
            for c of-type fixnum = (funcall (the function cmp) (svref a pos) (svref b pos))
            do (cond ((< c 0) (return t))
                     ((> c 0) (return nil)))
            finally (return nil)))))

(defun vector-iterator (rows &optional (start 0) (end (length rows)))
  (let ((i start))
    (declare (type fixnum i))
    (lambda ()
      (when (< i end)
        (prog1 (svref rows i) (incf i))))))

(defmethod compile-operator ((node pp-sort))
  (let ((open-child (compile-operator (pnode-child node)))
        (less (make-row-comparator (pp-sort-keys node))))
    (declare (type function open-child))
    (lambda ()
      (let ((iterator nil))
        (lambda ()
          (unless iterator
            (setf iterator (vector-iterator (stable-sort (drain (funcall open-child)) less))))
          (funcall (the function iterator)))))))

(defun limit-iterator (child limit offset)
  "Skip OFFSET rows of CHILD, then return at most LIMIT (NIL = unlimited)."
  (declare (type function child))
  (let ((to-skip (or offset 0))
        (emitted 0))
    (declare (type integer to-skip emitted))
    (lambda ()
      (loop while (and (plusp to-skip) (funcall child))
            do (decf to-skip))
      (setf to-skip 0)
      (when (or (null limit) (< emitted limit))
        (let ((row (funcall child)))
          (when row (incf emitted))
          row)))))

(defmethod compile-operator ((node pp-limit))
  (let ((open-child (compile-operator (pnode-child node)))
        (limit (evaluate-limit-expr (pp-limit-limit node) "LIMIT"))
        (offset (evaluate-limit-expr (pp-limit-offset node) "OFFSET")))
    (declare (type function open-child))
    (lambda ()
      (if (eql limit 0)
          (lambda () nil)
          (limit-iterator (funcall open-child) limit offset)))))

(defmethod compile-operator ((node pp-top-n))
  ;; ORDER BY ... LIMIT n: keep only the best LIMIT+OFFSET rows in a bounded
  ;; buffer that is re-sorted (stably) whenever it doubles.
  (let* ((open-child (compile-operator (pnode-child node)))
         (less (make-row-comparator (pp-top-n-keys node)))
         (limit (evaluate-limit-expr (pp-top-n-limit node) "LIMIT"))
         (offset (or (evaluate-limit-expr (pp-top-n-offset node) "OFFSET") 0))
         (keep (+ limit offset)))
    (declare (type function open-child less))
    (lambda ()
      (let ((iterator nil))
        (lambda ()
          (unless iterator
            (let ((buffer (make-array (max 16 (* 2 keep)) :adjustable t :fill-pointer 0))
                  (child (funcall open-child))
                  (count 0))
              (declare (type function child) (type fixnum count))
              (flet ((compact ()
                       (let ((sorted (stable-sort (subseq buffer 0) less)))
                         (setf (fill-pointer buffer) 0)
                         (loop for i below (min keep (length sorted))
                               do (vector-push-extend (svref sorted i) buffer)))))
                (unless (zerop keep)
                  (loop for row = (funcall child)
                        while row
                        do (counting-interrupts (count)
                             (vector-push-extend row buffer)
                             (when (>= (fill-pointer buffer) (max 16 (* 2 keep)))
                               (compact)))))
                (compact)
                (setf iterator (vector-iterator (coerce buffer 'simple-vector)
                                                (min offset (fill-pointer buffer))
                                                (fill-pointer buffer))))))
          (funcall (the function iterator)))))))

;;; ------------------------------------------------------------------
;;; UNION ALL (spec/changes/union-all.md)

(defun concatenating-opener (openers)
  "Opener of an iterator returning the items of the iterators opened by
OPENERS, one after another (each opened when the previous one is exhausted)."
  (lambda ()
    (let ((pending openers)
          (current nil))
      (lambda ()
        (loop
          (let ((item (and current (funcall (the function current)))))
            (when item (return item))
            (when (null pending) (return nil))
            (setf current (funcall (the function (pop pending))))))))))

(defmethod compile-operator ((node pp-union-all))
  (concatenating-opener (mapcar #'compile-operator (pnode-children node))))

