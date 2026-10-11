;;;; vsubqueries.lisp — vector kernels for uncorrelated subqueries.
;;;;
;;;; An uncorrelated subquery has the same value for every row, and it is
;;;; evaluated once per query (QUERY-SHARED-VALUE, shared by the parallel
;;;; workers). So an operator over a scalar subquery is compiled again, with
;;;; the subquery's value as a literal, when it is first evaluated (on the
;;;; first rows that need it, as the row evaluator would) — e.g.
;;;; `amount > (SELECT AVG(amount) ...)` becomes a typed column/constant
;;;; comparison; `x IN (subquery)` over INT64-like values probes an integer
;;;; key table built once from the subquery's rows.

(in-package #:polyquery)

(defun scalar-subquery-arg-p (e)
  (and (uncorrelated-subquery-p e) (eq (subquery-kind (b-op-info e)) :scalar)))

(defun compile-with-subquery-values (e)
  "Deferred kernel for the operator E when an argument is an uncorrelated
scalar subquery, else NIL."
  (when (and (not (subquery-op-p e)) (some #'scalar-subquery-arg-p (b-op-args e)))
    (let* ((args (b-op-args e))
           (subquery-fns (mapcar (lambda (a) (and (scalar-subquery-arg-p a) (compile-bexpr a))) args))
           (kind (type-vec-kind (bexpr-type e)))
           (kernel nil))
      (lambda (batch)
        (cond
          (kernel (funcall (the function kernel) batch))
          ((zerop (batch-count batch)) (null-vec kind 0))
          (t
           (setf kernel
                 (compile-vexpr
                  (make-b-op (bexpr-type e) (b-op-op e)
                             (loop for a in args
                                   for fn in subquery-fns
                                   collect (if fn
                                               (make-b-literal (bexpr-type a)
                                                               (funcall (the function fn) #()))
                                               a))
                             (b-op-info e))))
           (funcall (the function kernel) batch)))))))

(defun compile-vin-subquery (e)
  "Kernel for `x IN (uncorrelated subquery)` with INT64-like keys, or NIL."
  (let* ((sq (b-op-info e))
         (x (first (b-op-args e))))
    (when (and (uncorrelated-subquery-p e)
               (eq (subquery-kind sq) :in)
               (eq (type-vec-kind (bexpr-type x)) :i64))
      (let* ((column-type (column-def-type (first (bound-query-columns (subquery-query sq)))))
             (operand-type (bexpr-type x)))
        (when (and (eq (type-vec-kind column-type) :i64)
                   (not (eq (nth-value 2 (comparison-normalizers operand-type column-type)) :float64)))
          (let* ((open (let ((*parallel-disabled* t)) (compile-plan (subquery-plan sq))))
                 (key-fn (hash-key-normalizer column-type operand-type))
                 (probe (hash-key-normalizer operand-type column-type))
                 (probe-identity (eq probe #'identity))
                 (compute (lambda () (subquery-set-result open key-fn)))
                 (x-kernel (compile-vexpr x))
                 (table nil) (generic nil) (has-null nil) (empty nil))
            (declare (type function probe x-kernel))
            (flet ((prepare ()
                     ;; The subquery's distinct keys as an integer key table
                     ;; (or, if some key is not a 64-bit integer, its own table).
                     (let ((set (query-shared-value sq compute)))
                       (setf empty (value-set-empty set)
                             has-null (value-set-has-null set))
                       (let* ((keys (value-set-table set))
                              (tab (make-key-table 1 (hash-table-count keys) '(:i64))))
                         (if (loop for k being the hash-keys of keys
                                   always (typep k '(signed-byte 64)))
                             (loop for k being the hash-keys of keys
                                   do (int-key-probe tab k t))
                             (setf generic keys))
                         (setf table tab)))))
              (lambda (batch)
                (let ((n (batch-count batch)))
                  (declare (type fixnum n))
                  (when (and (null table) (plusp n)) (prepare))
                  (let* ((xv (funcall x-kernel batch))
                         (data (vec-data xv))
                         (validity (vec-validity xv))
                         (miss (if has-null +null+ nil))
                         (out (make-array n)))
                    (declare (type i64-vector data) (type (or null simple-bit-vector) validity))
                    (do-valid-rows (i n validity)
                      (setf (svref out i)
                            (if empty
                                nil
                                (let ((k (if probe-identity (aref data i) (funcall probe (aref data i)))))
                                  (cond (generic (if (gethash k generic) t miss))
                                        ((and (typep k '(signed-byte 64))
                                              (>= (int-key-probe table k nil) 0))
                                         t)
                                        (t miss)))))
                      ;; NULL IN (empty) is FALSE; otherwise NULL.
                      (setf (svref out i) (if empty nil +null+)))
                    (make-vec out)))))))))))
