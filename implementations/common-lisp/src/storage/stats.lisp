;;;; stats.lisp — per-table column statistics (indexes-and-planning.md §3).
;;;;
;;;; Statistics are computed from the data on first use and cached in the
;;;; (immutable) table, one column at a time, so a lazily decoded table only
;;;; decodes the columns whose statistics are requested.

(in-package #:polyquery)

(defstruct column-statistics
  (null-count 0 :type fixnum)
  (distinct-count 0 :type fixnum)        ; exact count of distinct non-NULL values
  (min +null+)                           ; :NULL when there is no non-NULL value
  (max +null+))

(defun distinct-key (v)
  "Key under which equal values collide (-0.0 and 0.0 are equal)."
  (if (and (floatp v) (zerop v)) 0d0 v))

(defun compute-column-statistics (table k)
  (let* ((type (table-column-type table k))
         (cmp (make-comparator type))
         (nulls 0)
         (lo +null+) (hi +null+)
         (seen (make-hash-table :test (if (eq (type-kind type) :string) 'equal 'eql))))
    (declare (type function cmp) (type fixnum nulls))
    (map-column-values
     (lambda (id v)
       (when (zerop (logand id 65535)) (check-interrupts))
       (if (null-value-p v)
           (incf nulls)
           (progn
             (setf (gethash (distinct-key v) seen) t)
             (when (or (null-value-p lo) (minusp (the fixnum (funcall cmp v lo)))) (setf lo v))
             (when (or (null-value-p hi) (plusp (the fixnum (funcall cmp v hi)))) (setf hi v)))))
     table k)
    (make-column-statistics :null-count nulls :distinct-count (hash-table-count seen)
                            :min lo :max hi)))

(defun table-column-statistics (table k)
  "Statistics of column K of TABLE (computed once, then cached)."
  (let ((cache (table-stats-cache table)))
    (or (svref cache k)
        (setf (svref cache k) (compute-column-statistics table k)))))

(defun table-stats-json (table)
  "The `stats` response fields of TABLE (protocol.md §5.8)."
  (list "table" (table-name table)
        "row_count" (table-row-count table)
        "layout" (table-layout-name table)
        "columns"
        (loop for def across (table-columns table)
              for k from 0
              for s = (table-column-statistics table k)
              for type = (column-def-type def)
              collect (jobj "name" (column-def-name def)
                            "type" (type-name-string type)
                            "null_count" (column-statistics-null-count s)
                            "distinct_count" (column-statistics-distinct-count s)
                            "min" (value-to-json (column-statistics-min s) type)
                            "max" (value-to-json (column-statistics-max s) type)))))
