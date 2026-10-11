;;;; keytable.lisp — hash table from key tuples to dense group ids.
;;;;
;;;; Used by vectorized grouping, DISTINCT and hash joins. Keys are hashed a
;;;; whole batch at a time; the table is open addressing with linear probing
;;;; over a flat FIXNUM array of group ids, and the per-group hashes and key
;;;; values are stored in separate dense arrays indexed by group id (so
;;;; probing touches one cache line of slots, and results can be read back
;;;; column-wise). Group ids are assigned in order of first appearance.
;;;;
;;;; Key values are runtime values (NULL is :NULL, a valid key: NULLs group
;;;; together); FLOAT64 -0.0 is normalized to 0.0. Lookups never modify the
;;;; table, so a built table may be probed by several threads at once.

(in-package #:polyquery)

(defconstant +hash-mask+ (1- (expt 2 61)))

(declaim (inline mix-hash))
(defun mix-hash (x)
  "Scramble the 64-bit word X (murmur3 finalizer), result a non-negative fixnum."
  (declare (type (unsigned-byte 64) x))
  (let* ((x (logand (* (logxor x (ash x -33)) #xff51afd7ed558ccd) #xFFFFFFFFFFFFFFFF))
         (x (logand (* (logxor x (ash x -33)) #xc4ceb9fe1a85ec53) #xFFFFFFFFFFFFFFFF)))
    (logand (logxor x (ash x -33)) +hash-mask+)))

(declaim (inline hash-i64))
(defun hash-i64 (v)
  (declare (type (signed-byte 64) v))
  (mix-hash (logand v #xFFFFFFFFFFFFFFFF)))

(defconstant +null-key-hash+ 1234567)

(defun normalize-key-value (v)
  (if (and (floatp v) (zerop v)) 0d0 v))

(defun hash-key-value (v)
  "Hash of one runtime key value (consistent with KEY-VALUE-EQUAL)."
  (typecase v
    ((signed-byte 64) (hash-i64 v))
    (double-float (mix-hash (logand (sxhash (normalize-key-value v)) +hash-mask+)))
    (t (mix-hash (logand (sxhash v) +hash-mask+)))))

(declaim (inline key-value-equal))
(defun key-value-equal (a b)
  (or (eql a b)
      (and (stringp a) (stringp b) (string= a b))
      (and (floatp a) (floatp b) (= a b))))

(declaim (inline combine-hash))
(defun combine-hash (h k)
  "Hash of a key tuple extended by a value with hash K (modular arithmetic)."
  (declare (type (unsigned-byte 61) h k))
  (logand (+ (logand (* h 31) #xFFFFFFFFFFFFFFFF) k) +hash-mask+))

(defun hash-key-vecs (vecs n)
  "Index vector of the combined hashes of rows [0, N) of the key VECS."
  (declare (type fixnum n))
  (let ((hashes (make-index-vector n)))
    (fill hashes 0)
    (dolist (vec vecs hashes)
      (let ((data (vec-data vec))
            (validity (vec-validity vec)))
        (macrolet ((combine (i h)
                     `(setf (aref hashes ,i)
                            (combine-hash (aref hashes ,i) ,h))))
          (etypecase data
            (i64-vector
             (if validity
                 (dotimes (i n)
                   (combine i (if (zerop (sbit validity i)) +null-key-hash+ (hash-i64 (aref data i)))))
                 (dotimes (i n)
                   (combine i (hash-i64 (aref data i))))))
            (f64-vector
             (dotimes (i n)
               (combine i (if (and validity (zerop (sbit validity i)))
                              +null-key-hash+
                              (hash-key-value (aref data i))))))
            (simple-vector
             (dotimes (i n)
               (let ((v (svref data i)))
                 (combine i (if (eq v +null+) +null-key-hash+ (hash-key-value v))))))))))))

(defstruct (key-table (:constructor %make-key-table))
  (width 0 :type fixnum)
  (keys #() :type simple-vector)          ; per key column: SIMPLE-VECTOR of values by group id
  (hashes (make-index-vector 0) :type index-vector)    ; per group id
  (slots (make-index-vector 0) :type index-vector)     ; group id or -1
  (mask 0 :type fixnum)
  (count 0 :type fixnum))

(defun make-key-table (width &optional (expected 16))
  (let ((size 16))
    (loop while (< size (* 2 expected)) do (setf size (* 2 size)))
    (%make-key-table :width width
                     :keys (let ((v (make-array width)))
                             (dotimes (k width v) (setf (svref v k) (make-array (floor size 2)))))
                     :hashes (make-index-vector (floor size 2))
                     :slots (make-array size :element-type 'fixnum :initial-element -1)
                     :mask (1- size))))

(defun key-table-key (table k gid)
  "Value of key column K of group GID."
  (svref (svref (key-table-keys table) k) gid))

(defun key-table-grow (table)
  "Double the slot array and the per-group arrays."
  (let* ((size (* 2 (length (key-table-slots table))))
         (slots (make-array size :element-type 'fixnum :initial-element -1))
         (mask (1- size))
         (count (key-table-count table))
         (hashes (make-index-vector (floor size 2))))
    (replace hashes (key-table-hashes table))
    (dotimes (g count)
      (let ((pos (logand (aref hashes g) mask)))
        (loop until (= (aref slots pos) -1)
              do (setf pos (logand (1+ pos) mask)))
        (setf (aref slots pos) g)))
    (let ((keys (key-table-keys table)))
      (dotimes (k (length keys))
        (let ((new (make-array (floor size 2))))
          (replace new (svref keys k))
          (setf (svref keys k) new))))
    (setf (key-table-slots table) slots
          (key-table-mask table) mask
          (key-table-hashes table) hashes)))

(defmacro probe-key-table ((table hash gid-var equal-form) found-form missing-form)
  "Probe TABLE for HASH; for each candidate group GID-VAR with the same hash
EQUAL-FORM decides equality. Runs FOUND-FORM (GID-VAR bound) or MISSING-FORM
(with POS-VAR bound to the free slot)."
  (let ((pos (gensym "POS")) (slots (gensym "SLOTS")) (mask (gensym "MASK"))
        (hashes (gensym "HASHES")))
    `(let* ((,slots (key-table-slots ,table))
            (,hashes (key-table-hashes ,table))
            (,mask (key-table-mask ,table))
            (,pos (logand ,hash ,mask)))
       (declare (type index-vector ,slots ,hashes) (type fixnum ,pos ,mask))
       (loop
         (let ((,gid-var (aref ,slots ,pos)))
           (declare (type fixnum ,gid-var))
           (cond ((= ,gid-var -1)
                  (let ((free-pos ,pos))
                    (declare (ignorable free-pos))
                    (return ,missing-form)))
                 ((and (= (aref ,hashes ,gid-var) ,hash) ,equal-form)
                  (return ,found-form))))
         (setf ,pos (logand (1+ ,pos) ,mask))))))

(defun key-table-insert-at (table pos hash values-fn)
  "Add a new group at the free slot POS; VALUES-FN (k) gives its key values."
  (declare (type function values-fn) (type fixnum pos))
  (let ((g (key-table-count table)))
    (setf (aref (key-table-slots table) pos) g
          (aref (key-table-hashes table) g) hash)
    (let ((keys (key-table-keys table)))
      (dotimes (k (key-table-width table))
        (setf (svref (svref keys k) g) (funcall values-fn k))))
    (setf (key-table-count table) (1+ g))
    ;; Keep room for the next group (load factor <= 1/2).
    (when (>= (1+ g) (length (key-table-hashes table)))
      (key-table-grow table))
    g))

(defun key-table-map-batch (table vecs n gids add)
  "Fill GIDS[0..N) with the group ids of the rows of the key VECS; new keys
are added when ADD, else their id is -1. Returns GIDS."
  (declare (type index-vector gids) (type fixnum n))
  (let ((hashes (hash-key-vecs vecs n))
        (vecs (coerce vecs 'simple-vector)))
    (if (and (= (length vecs) 1) (typep (vec-data (svref vecs 0)) 'i64-vector)
             (null (vec-validity (svref vecs 0))))
        ;; Fast path: one non-NULL INT64-like key column.
        (let ((data (vec-data (svref vecs 0))))
          (declare (type i64-vector data))
          (dotimes (i n)
            (let ((v (aref data i))
                  (h (aref hashes i)))
              (setf (aref gids i)
                    (probe-key-table (table h g (eql (svref (svref (key-table-keys table) 0) g) v))
                                     g
                                     (if add
                                         (key-table-insert-at table free-pos h
                                                              (lambda (k) (declare (ignore k)) v))
                                         -1))))))
        (let ((width (length vecs)))
          (dotimes (i n)
            (let ((h (aref hashes i)))
              (setf (aref gids i)
                    (probe-key-table (table h g
                                            (let ((keys (key-table-keys table)))
                                              (dotimes (k width t)
                                                (unless (key-value-equal
                                                         (svref (svref keys k) g)
                                                         (normalize-key-value (vec-ref (svref vecs k) i)))
                                                  (return nil)))))
                                     g
                                     (if add
                                         (key-table-insert-at
                                          table free-pos h
                                          (lambda (k) (normalize-key-value (vec-ref (svref vecs k) i))))
                                         -1)))))))
    gids))

(defun key-table-intern-group (table other g)
  "Group id in TABLE of the key of group G of the key table OTHER (added if new)."
  (let ((h (aref (key-table-hashes other) g))
        (width (key-table-width table))
        (other-keys (key-table-keys other)))
    (probe-key-table (table h gid
                            (let ((keys (key-table-keys table)))
                              (dotimes (k width t)
                                (unless (key-value-equal (svref (svref keys k) gid)
                                                         (svref (svref other-keys k) g))
                                  (return nil)))))
                     gid
                     (key-table-insert-at table free-pos h
                                          (lambda (k) (svref (svref other-keys k) g))))))
