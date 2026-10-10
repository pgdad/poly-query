;;;; index.lisp — single-column secondary indexes (indexes-and-planning.md §2).
;;;;
;;;; HASH   a hash table from (normalized) key value to the ascending vector of
;;;;        row ids holding it; supports equality lookups.
;;;; BTREE  an ordered structure realised as a sorted permutation: the
;;;;        non-NULL key values in ascending order with their row ids
;;;;        (ties in row id order); supports equality and range lookups by
;;;;        binary search.
;;;; NULLs are never stored, so no lookup returns them. Indexes are built from
;;;; an immutable table and are dropped together with it.

(in-package #:polyquery)

(defstruct (table-index (:constructor %make-table-index))
  (name "" :type string)
  table                                  ; the TABLE the index was built on
  (column 0 :type fixnum)                ; column position in the table
  (kind :btree)                          ; :HASH or :BTREE
  (map nil)                              ; HASH: hash table key -> row-id vector
  (keys #() :type simple-vector)         ; BTREE: sorted key values
  (ids #() :type simple-vector)          ; BTREE: row ids aligned with KEYS
  (distinct-count 0 :type fixnum))

(defun table-index-column-name (index)
  (column-def-name (svref (table-columns (table-index-table index)) (table-index-column index))))

(defun table-index-kind-name (index)
  (ecase (table-index-kind index) (:hash "HASH") (:btree "BTREE")))

(defun table-index-json (index)
  (jobj "name" (table-index-name index)
        "column" (table-index-column-name index)
        "kind" (table-index-kind-name index)))

(defun index-key-test (type)
  (if (eq (type-kind type) :string) 'equal 'eql))

(defun build-hash-index (index)
  (let* ((table (table-index-table index))
         (k (table-index-column index))
         (map (make-hash-table :test (index-key-test (table-column-type table k)))))
    (map-column-values (lambda (id v)
                         (when (zerop (logand id 65535)) (check-interrupts))
                         (unless (null-value-p v)
                           (push id (gethash (distinct-key v) map))))
                       table k)
    (maphash (lambda (key ids) (setf (gethash key map) (coerce (nreverse ids) 'simple-vector)))
             map)
    (setf (table-index-map index) map
          (table-index-distinct-count index) (hash-table-count map))))

(defun build-btree-index (index)
  (let* ((table (table-index-table index))
         (k (table-index-column index))
         (cmp (make-comparator (table-column-type table k)))
         (values (table-column-values table k))
         (ids (coerce (loop for id below (length values)
                            unless (null-value-p (svref values id)) collect id)
                      'simple-vector)))
    (declare (type function cmp))
    (setf ids (stable-sort ids (lambda (a b) (minusp (the fixnum (funcall cmp (svref values a)
                                                                         (svref values b)))))))
    (let ((keys (map 'simple-vector (lambda (id) (svref values id)) ids))
          (distinct 0))
      (dotimes (i (length keys))
        (when (or (zerop i) (/= 0 (the fixnum (funcall cmp (svref keys (1- i)) (svref keys i)))))
          (incf distinct)))
      (setf (table-index-keys index) keys
            (table-index-ids index) ids
            (table-index-distinct-count index) distinct))))

(defun build-table-index (name table column kind)
  "Build index NAME of KIND (:HASH or :BTREE) on column position COLUMN of TABLE."
  (let ((index (%make-table-index :name name :table table :column column :kind kind)))
    (ecase kind
      (:hash (build-hash-index index))
      (:btree (build-btree-index index)))
    index))

;;; ------------------------------------------------------------------
;;; Lookups. Every lookup returns a list of row-id vectors; callers merge them.

(defun hash-index-lookup (index key)
  "Row ids whose column value has the normalized KEY (a vector, possibly empty)."
  (or (gethash (distinct-key key) (table-index-map index)) #()))

(defun btree-lower-bound (keys test)
  "First position in the sorted KEYS for which TEST (a monotone predicate:
false ... false true ... true) holds; (length keys) if none."
  (declare (type simple-vector keys) (type function test))
  (let ((lo 0) (hi (length keys)))
    (declare (type fixnum lo hi))
    (loop while (< lo hi)
          do (let ((mid (floor (+ lo hi) 2)))
               (if (funcall test (svref keys mid))
                   (setf hi mid)
                   (setf lo (1+ mid)))))
    lo))

(defun btree-index-range (index low high)
  "Row ids of keys within the bounds LOW and HIGH. A bound is NIL (open) or
a list (compare-fn inclusive-p) where COMPARE-FN maps a key to -1/0/1 as it
compares to the bound's constant."
  (let* ((keys (table-index-keys index))
         (start (if low
                    (destructuring-bind (cmp inclusive) low
                      (declare (type function cmp))
                      (btree-lower-bound keys (if inclusive
                                                  (lambda (k) (>= (the fixnum (funcall cmp k)) 0))
                                                  (lambda (k) (> (the fixnum (funcall cmp k)) 0)))))
                    0))
         (end (if high
                  (destructuring-bind (cmp inclusive) high
                    (declare (type function cmp))
                    (btree-lower-bound keys (if inclusive
                                                (lambda (k) (> (the fixnum (funcall cmp k)) 0))
                                                (lambda (k) (>= (the fixnum (funcall cmp k)) 0)))))
                  (length keys))))
    (if (< start end)
        (subseq (table-index-ids index) start end)
        #())))
