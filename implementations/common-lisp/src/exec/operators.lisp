;;;; operators.lisp — row-at-a-time (Volcano) physical operators.
;;;;
;;;; BUILD-ITERATOR turns a plan node into an iterator: a function of no
;;;; arguments returning the next row (a SIMPLE-VECTOR) or NIL at the end.

(in-package #:polyquery)

(defconstant +interrupt-check-interval+ 4096
  "Rows processed between checks for timeout/cancellation.")

(defgeneric build-iterator (node)
  (:documentation "Return the iterator implementing plan NODE."))

(defmethod build-iterator ((node plan-values))
  (let ((done nil))
    (lambda ()
      (unless done
        (setf done t)
        (vector)))))

(defmethod build-iterator ((node plan-scan))
  (let* ((table (plan-scan-table node))
         (n (table-row-count table))
         (vectors (map 'simple-vector (lambda (c) (table-column-vector table c))
                       (plan-scan-columns node)))
         (width (length vectors))
         (i 0))
    (declare (type fixnum n i width) (type simple-vector vectors))
    (lambda ()
      (when (< i n)
        (when (zerop (mod i +interrupt-check-interval+))
          (check-interrupts))
        (let ((row (make-array width)))
          (dotimes (k width)
            (setf (svref row k) (svref (svref vectors k) i)))
          (incf i)
          row)))))

(defmethod build-iterator ((node plan-filter))
  (let ((child (build-iterator (plan-child node)))
        (pred (compile-bexpr (plan-filter-predicate node)))
        (count 0))
    (declare (type function child pred) (type fixnum count))
    (lambda ()
      (loop
        (let ((row (funcall child)))
          (when (null row) (return nil))
          (when (zerop (mod (incf count) +interrupt-check-interval+))
            (check-interrupts))
          (when (eq (funcall pred row) t)
            (return row)))))))

(defmethod build-iterator ((node plan-project))
  (let ((child (build-iterator (plan-child node)))
        (fns (coerce (mapcar #'compile-bexpr (plan-project-exprs node)) 'simple-vector)))
    (declare (type function child))
    (lambda ()
      (let ((row (funcall child)))
        (when row
          (let ((out (make-array (length fns))))
            (dotimes (k (length fns) out)
              (setf (svref out k) (funcall (the function (svref fns k)) row)))))))))

(defmethod build-iterator ((node plan-aggregate))
  ;; Phase 1: whole-input aggregation producing exactly one row.
  (when (plan-aggregate-group-by node)
    (unsupported-error "GROUP BY is not supported"))
  (let ((child (build-iterator (plan-child node)))
        (aggs (plan-aggregate-aggregates node))
        (done nil))
    (declare (type function child))
    (lambda ()
      (unless done
        (setf done t)
        (let* ((n (length aggs))
               (arg-fns (map 'simple-vector
                             (lambda (a) (if (b-agg-args a)
                                             (compile-bexpr (first (b-agg-args a)))
                                             (constantly t)))
                             aggs))
               (steps (make-array n))
               (finishers (make-array n)))
          (loop for a in aggs
                for k from 0
                do (multiple-value-bind (step finish) (funcall (make-accumulator-factory a))
                     (setf (svref steps k) step (svref finishers k) finish)))
          (loop for row = (funcall child)
                while row
                do (dotimes (k n)
                     (funcall (the function (svref steps k))
                              (funcall (the function (svref arg-fns k)) row))))
          (let ((out (make-array n)))
            (dotimes (k n out)
              (setf (svref out k) (funcall (the function (svref finishers k)))))))))))

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

(defmethod build-iterator ((node plan-sort))
  (let ((child (build-iterator (plan-child node)))
        (less (make-row-comparator (plan-sort-keys node)))
        (rows nil)
        (i 0))
    (declare (type function child) (type fixnum i))
    (lambda ()
      (unless rows
        (let ((acc (make-array 64 :adjustable t :fill-pointer 0)))
          (loop for row = (funcall child)
                while row
                do (when (zerop (mod (fill-pointer acc) +interrupt-check-interval+))
                     (check-interrupts)
                     (charge-memory (* +interrupt-check-interval+ (row-footprint (length row)))))
                   (vector-push-extend row acc))
          (setf rows (stable-sort (coerce acc 'simple-vector) less))))
      (when (< i (length rows))
        (prog1 (svref rows i) (incf i))))))

(defmethod build-iterator ((node plan-limit))
  (let ((child (build-iterator (plan-child node)))
        (limit (plan-limit-limit node))
        (to-skip (plan-limit-offset node))
        (emitted 0))
    (declare (type function child) (type integer emitted))
    (lambda ()
      (loop while (and (plusp to-skip) (funcall child))
            do (decf to-skip))
      (when (or (null limit) (< emitted limit))
        (let ((row (funcall child)))
          (when row (incf emitted))
          row)))))
