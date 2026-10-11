;;;; aggregates.lisp — aggregate accumulators (functions.md §2).
;;;;
;;;; MAKE-ACCUMULATOR-FACTORY returns a function that creates a fresh
;;;; accumulator, represented as two closures: STEP (called with each input
;;;; value) and FINISH (returns the aggregate result). One accumulator is
;;;; created per group.

(in-package #:polyquery)

(defun make-accumulator-factory (agg)
  (let* ((fn (b-agg-fn agg))
         (arg-type (if (b-agg-args agg) (bexpr-type (first (b-agg-args agg))) :int64))
         (base (make-base-accumulator-factory fn arg-type)))
    (if (and (b-agg-distinct agg) (not (member fn '(:min :max))))
        (lambda ()
          (multiple-value-bind (step finish) (funcall base)
            (declare (type function step))
            (let ((seen (make-hash-table :test 'equal)))
              (values (lambda (v)
                        (unless (null-value-p v)
                          (let ((k (distinct-key v)))
                            (unless (gethash k seen)
                              (setf (gethash k seen) t)
                              (funcall step v)))))
                      finish))))
        base)))

(defun make-base-accumulator-factory (fn arg-type)
  (ecase fn
    (:count-star
     (lambda ()
       (let ((n 0))
         (declare (type fixnum n))
         (values (lambda (v) (declare (ignore v)) (incf n))
                 (lambda () n)))))
    (:count
     (lambda ()
       (let ((n 0))
         (declare (type fixnum n))
         (values (lambda (v) (unless (null-value-p v) (incf n)))
                 (lambda () n)))))
    (:sum (make-sum-factory arg-type))
    (:avg (make-avg-factory arg-type))
    ((:min :max)
     (let ((cmp (make-comparator arg-type))
           (sign (if (eq fn :min) -1 1)))
       (declare (type function cmp))
       (lambda ()
         (let ((best +null+))
           (values (lambda (v)
                     (unless (null-value-p v)
                       (when (or (null-value-p best) (= (funcall cmp v best) sign))
                         (setf best v))))
                   (lambda () best))))))))

(defun make-sum-factory (arg-type)
  (if (eq (type-kind arg-type) :float64)
      (lambda ()
        (let ((sum 0d0) (any nil))
          (declare (type double-float sum))
          (values (lambda (v) (unless (null-value-p v) (setf any t) (incf sum (the double-float v))))
                  (lambda () (if any (check-finite sum) +null+)))))
      ;; INT64 and DECIMAL sums are exact (unbounded integers); only the final
      ;; result is range checked.
      (let ((decimal (and (decimal-type-p arg-type) (decimal-result-precision arg-type))))
        (lambda ()
          (let ((sum 0) (any nil))
            (declare (type integer sum))
            (values (lambda (v) (unless (null-value-p v) (setf any t) (incf sum v)))
                    (lambda ()
                      (cond ((not any) +null+)
                            (decimal (if (fits-precision-p sum decimal)
                                         sum
                                         (overflow-error "DECIMAL SUM exceeds ~D digits" decimal)))
                            (t (check-int64 sum))))))))))

(defun make-avg-factory (arg-type)
  (if (eq (type-kind arg-type) :float64)
      (lambda ()
        (let ((sum 0d0) (n 0))
          (declare (type double-float sum) (type fixnum n))
          (values (lambda (v) (unless (null-value-p v) (incf n) (incf sum (the double-float v))))
                  (lambda () (if (zerop n) +null+ (check-finite (/ sum n)))))))
      (let ((divisor (if (decimal-type-p arg-type) (pow10 (decimal-scale arg-type)) 1)))
        (lambda ()
          (let ((sum 0) (n 0))
            (declare (type integer sum) (type fixnum n))
            (values (lambda (v) (unless (null-value-p v) (incf n) (incf sum v)))
                    (lambda ()
                      (if (zerop n)
                          +null+
                          (values (rational-to-double (/ sum (* n divisor))))))))))))
