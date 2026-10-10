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

(defun compile-plan (node)
  (compile-operator node))

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

(defmethod compile-operator ((node pp-table-scan))
  (let* ((table (pp-table-scan-table node))
         (n (table-row-count table))
         (vectors (map 'simple-vector (lambda (c) (table-column-vector table c))
                       (pp-table-scan-column-indexes node)))
         (width (length vectors)))
    (declare (type fixnum n width) (type simple-vector vectors))
    (lambda ()
      (let ((i 0))
        (declare (type fixnum i))
        (lambda ()
          (when (< i n)
            (when (zerop (logand i 4095))
              (check-interrupts))
            (let ((row (make-array width)))
              (dotimes (k width)
                (setf (svref row k) (svref (svref vectors k) i)))
              (incf i)
              row)))))))

;;; ------------------------------------------------------------------
;;; Filter and projection

(defmethod compile-operator ((node pp-filter))
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

(defun join-row-counter ()
  "Function to call per produced join row; enforces --max-join-rows."
  (let ((count 0)
        (limit (and *query-context* (query-context-max-join-rows *query-context*))))
    (declare (type fixnum count))
    (lambda ()
      (when (and limit (> (incf count) limit))
        (resource-limit-error "join produced more than ~D rows (--max-join-rows)" limit))
      (when (zerop (logand count 4095))
        (check-interrupts)))))

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
          (right-width (length (pnode-columns right))))
      (declare (type function open-left open-right))
      (lambda ()
        (let ((rights nil))
          (make-join-iterator
           kind (funcall open-left)
           (lambda (lrow)
             (unless rights (setf rights (drain (funcall open-right))))
             (let ((i 0) (n (length rights)))
               (declare (type fixnum i n))
               (lambda ()
                 (loop
                   (when (>= i n) (return nil))
                   (let ((r (svref rights i)))
                     (incf i)
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

(defmethod compile-operator ((node pp-hash-join))
  (destructuring-bind (left right) (pnode-children node)
    (let* ((open-left (compile-operator left))
           (open-right (compile-operator right))
           (lkeys (pp-hash-join-left-keys node))
           (rkeys (pp-hash-join-right-keys node))
           (left-key (make-key-function lkeys rkeys))
           (right-key (make-key-function rkeys lkeys))
           (residual (and (pp-hash-join-residual node) (compile-bexpr (pp-hash-join-residual node))))
           (kind (pp-hash-join-kind node))
           (right-width (length (pnode-columns right))))
      (declare (type function open-left open-right left-key right-key))
      (lambda ()
        (let ((table nil))
          (flet ((build ()
                   (let ((h (make-hash-table :test 'equal))
                         (next (funcall open-right))
                         (n 0))
                     (declare (type function next) (type fixnum n))
                     (loop for row = (funcall next)
                           while row
                           do (when (zerop (logand (incf n) 4095))
                                (check-interrupts)
                                (charge-memory (* 4096 (row-footprint (+ 4 (length row))))))
                              (let ((k (funcall right-key row)))
                                (when k (push row (gethash k h)))))
                     ;; Keep build rows in input order.
                     (maphash (lambda (k rows) (setf (gethash k h) (nreverse rows))) h)
                     h)))
            (make-join-iterator
             kind (funcall open-left)
             (lambda (lrow)
               (unless table (setf table (build)))
               (let* ((k (funcall left-key lrow))
                      (candidates (and k (gethash k table))))
                 (lambda ()
                   (loop
                     (when (null candidates) (return nil))
                     (let ((r (pop candidates)))
                       (when (or (null residual)
                                 (eq (funcall (the function residual) (concat-rows lrow r)) t))
                         (return r)))))))
             right-width)))))))

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
