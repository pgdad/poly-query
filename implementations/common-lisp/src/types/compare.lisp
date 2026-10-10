;;;; compare.lisp — total ordering and equality of values (types.md §5, §7).

(in-package #:polyquery)

(defun make-comparator (type)
  "Return a function (a b) -> -1, 0 or 1 ordering two non-NULL values of TYPE."
  (ecase (type-kind type)
    ((:int64 :decimal :date :timestamp)
     (lambda (a b)
       (declare (type integer a b))
       (cond ((< a b) -1) ((> a b) 1) (t 0))))
    (:float64
     (lambda (a b)
       (declare (type double-float a b))
       (cond ((< a b) -1) ((> a b) 1) (t 0))))
    (:string
     (lambda (a b)
       (declare (type string a b))
       (cond ((string< a b) -1) ((string= a b) 0) (t 1))))
    (:boolean
     (lambda (a b)
       (cond ((eq a b) 0) (a 1) (t -1))))
    (:null
     (lambda (a b) (declare (ignore a b)) 0))))

(defun make-sort-key-comparator (type descending nulls-first)
  "Comparator over possibly-NULL values for one ORDER BY key."
  (let ((cmp (make-comparator type))
        (null-order (if nulls-first -1 1)))
    (lambda (a b)
      (let ((an (null-value-p a)) (bn (null-value-p b)))
        (cond ((and an bn) 0)
              (an null-order)
              (bn (- null-order))
              (descending (- (funcall cmp a b)))
              (t (funcall cmp a b)))))))
