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
;;;;
;;;; A table made for a query with native kernels hashes INT64-like key
;;;; columns with pqk_hash_i64, the same murmur3 finalizer as HASH-I64.

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

(defun native-key-hashes (data n)
  "(UNSIGNED-BYTE 64) vector of the HASH-I64 hashes (before masking) of the
first N values of DATA, computed by pqk_hash_i64."
  (native-hash-i64 data n (make-array n :element-type '(unsigned-byte 64))))

(defun hash-key-vecs (vecs n &optional native)
  "Index vector of the combined hashes of rows [0, N) of the key VECS
(INT64-like keys hashed by the native kernel when NATIVE)."
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
             (if native
                 (let ((native-hashes (native-key-hashes data n)))
                   (declare (type (simple-array (unsigned-byte 64) (*)) native-hashes))
                   (dotimes (i n)
                     (combine i (if (and validity (zerop (sbit validity i)))
                                    +null-key-hash+
                                    (logand (aref native-hashes i) +hash-mask+)))))
             (if validity
                 (dotimes (i n)
                   (combine i (if (zerop (sbit validity i)) +null-key-hash+ (hash-i64 (aref data i)))))
                 (dotimes (i n)
                   (combine i (hash-i64 (aref data i)))))))
            (f64-vector
             (dotimes (i n)
               (combine i (if (and validity (zerop (sbit validity i)))
                              +null-key-hash+
                              (hash-key-value (aref data i))))))
            (simple-vector
             (let ((codes (vec-codes vec)))
               (if codes
                   ;; Dictionary codes: hash each distinct value once.
                   (let ((entry-hashes (dictionary-key-hashes (vec-dict vec))))
                     (declare (type index-vector entry-hashes))
                     (dotimes (i n)
                       (combine i (if (eq (svref data i) +null+)
                                      +null-key-hash+
                                      (aref entry-hashes (aref codes i))))))
                   (dotimes (i n)
                     (let ((v (svref data i)))
                       (combine i (if (eq v +null+) +null-key-hash+ (hash-key-value v))))))))))))))

(defun dictionary-key-hashes (store)
  "Key hashes of the entries of the DICT-COLUMN STORE (computed once)."
  (or (dict-column-key-hashes store)
      (setf (dict-column-key-hashes store)
            (let* ((dict (dict-column-dictionary store))
                   (hashes (make-index-vector (length dict))))
              (dotimes (k (length dict) hashes)
                (setf (aref hashes k) (hash-key-value (svref dict k))))))))

;;; A key table with a single INT64-like key column (KINDS = (:I64)) keeps
;;; its keys inline: INT-SLOTS holds (key, group id + 1) pairs, so a probe
;;; reads one cache line and never consults HASHES; the NULL key, if present,
;;; is the group NULL-GID outside the slot array.

(defstruct (key-table (:constructor %make-key-table))
  (width 0 :type fixnum)
  (keys #() :type simple-vector)          ; per key column: SIMPLE-VECTOR of values by group id
  (hashes (make-index-vector 0) :type index-vector)    ; per group id (generic tables)
  (slots (make-index-vector 0) :type index-vector)     ; group id or -1 (generic tables)
  (int-slots nil :type (or null i64-vector))           ; (key, gid + 1) pairs (integer tables)
  (null-gid -1 :type fixnum)                           ; group of the NULL key (integer tables)
  (mask 0 :type fixnum)
  (count 0 :type fixnum)
  (native nil))                                        ; hash with pqk_hash_i64

(defun make-key-table (width &optional (expected 16) kinds native)
  "Empty table for keys of WIDTH columns (of vector KINDS, when known);
NATIVE hashes INT64-like keys with the native kernel."
  (let ((size 16)
        (int-mode (and (= width 1) (equal kinds '(:i64)))))
    (loop while (< size (* 2 expected)) do (setf size (* 2 size)))
    (%make-key-table :width width
                     :native native
                     :keys (let ((v (make-array width)))
                             (dotimes (k width v) (setf (svref v k) (make-array (floor size 2)))))
                     :hashes (make-index-vector (if int-mode 0 (floor size 2)))
                     :slots (if int-mode
                                (make-index-vector 0)
                                (make-array size :element-type 'fixnum :initial-element -1))
                     :int-slots (and int-mode
                                     (make-array (* 2 size) :element-type '(signed-byte 64)
                                                            :initial-element 0))
                     :mask (1- size))))

(defun key-table-key (table k gid)
  "Value of key column K of group GID."
  (svref (svref (key-table-keys table) k) gid))

(defun key-table-capacity (table)
  "Number of groups the per-group arrays can hold."
  (length (the simple-vector (svref (key-table-keys table) 0))))

(defun grow-key-columns (table capacity)
  (let ((keys (key-table-keys table)))
    (dotimes (k (length keys))
      (let ((new (make-array capacity)))
        (replace new (svref keys k))
        (setf (svref keys k) new)))))

(defun key-table-grow (table)
  "Double the slot array and the per-group arrays."
  (if (key-table-int-slots table)
      (let* ((size (* 2 (1+ (key-table-mask table))))
             (slots (make-array (* 2 size) :element-type '(signed-byte 64) :initial-element 0))
             (mask (1- size))
             (keys (svref (key-table-keys table) 0)))
        (declare (type simple-vector keys))
        (dotimes (g (key-table-count table))
          (let ((v (svref keys g)))
            (unless (eq v +null+)
              (let ((pos (logand (hash-i64 v) mask)))
                (declare (type fixnum pos))
                (loop until (zerop (aref slots (1+ (* 2 pos))))
                      do (setf pos (logand (1+ pos) mask)))
                (setf (aref slots (* 2 pos)) v
                      (aref slots (1+ (* 2 pos))) (1+ g))))))
        (grow-key-columns table (floor size 2))
        (setf (key-table-int-slots table) slots
              (key-table-mask table) mask))
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
        (grow-key-columns table (floor size 2))
        (setf (key-table-slots table) slots
              (key-table-mask table) mask
              (key-table-hashes table) hashes))))

(defun key-table-new-group (table values-fn)
  "Allocate the next group id with key values (VALUES-FN k)."
  (declare (type function values-fn))
  (let ((g (key-table-count table))
        (keys (key-table-keys table)))
    (dotimes (k (key-table-width table))
      (setf (svref (svref keys k) g) (funcall values-fn k)))
    (setf (key-table-count table) (1+ g))
    g))

(defun key-table-ensure-room (table)
  ;; Keep room for the next group (load factor <= 1/2).
  (when (>= (key-table-count table) (key-table-capacity table))
    (key-table-grow table)))

;;; Integer tables

(declaim (inline int-key-probe-hashed int-key-probe))
(defun int-key-probe-hashed (table v hash add)
  "Group id of the integer key V whose HASH-I64 is HASH (added when ADD,
else -1 if absent)."
  (declare (type (signed-byte 64) v) (type (unsigned-byte 64) hash))
  (let* ((slots (key-table-int-slots table))
         (mask (key-table-mask table))
         (pos (logand hash mask)))
    (declare (type i64-vector slots) (type fixnum mask pos))
    (loop
      (let ((g1 (aref slots (1+ (* 2 pos)))))
        (cond ((zerop g1)
               (return
                 (if add
                     (let ((g (key-table-new-group table (lambda (k) (declare (ignore k)) v))))
                       (setf (aref slots (* 2 pos)) v
                             (aref slots (1+ (* 2 pos))) (1+ g))
                       (key-table-ensure-room table)
                       g)
                     -1)))
              ((= (aref slots (* 2 pos)) v) (return (1- g1)))))
      (setf pos (logand (1+ pos) mask)))))

(defun int-key-probe (table v add)
  "Group id of the integer key V (added when ADD, else -1 if absent)."
  (declare (type (signed-byte 64) v))
  (int-key-probe-hashed table v (hash-i64 v) add))

(defun int-key-null-group (table add)
  (let ((g (key-table-null-gid table)))
    (cond ((>= g 0) g)
          ((not add) -1)
          (t (let ((g (key-table-new-group table (lambda (k) (declare (ignore k)) +null+))))
               (setf (key-table-null-gid table) g)
               (key-table-ensure-room table)
               g)))))

(defun int-key-group (table v add)
  (if (eq v +null+)
      (int-key-null-group table add)
      (int-key-probe table v add)))

;;; Generic tables

(defmacro probe-key-table ((table hash gid-var equal-form) found-form missing-form)
  "Probe the generic TABLE for HASH; for each candidate group GID-VAR with the
same hash EQUAL-FORM decides equality. Runs FOUND-FORM (GID-VAR bound) or
MISSING-FORM (with FREE-POS bound to the free slot)."
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
  "Add a new group at the free slot POS of a generic table."
  (declare (type fixnum pos))
  (let ((g (key-table-new-group table values-fn)))
    (setf (aref (key-table-slots table) pos) g
          (aref (key-table-hashes table) g) hash)
    (key-table-ensure-room table)
    g))

(defun key-table-map-batch (table vecs n gids add)
  "Fill GIDS[0..N) with the group ids of the rows of the key VECS; new keys
are added when ADD, else their id is -1. Returns GIDS."
  (declare (type index-vector gids) (type fixnum n))
  (if (key-table-int-slots table)
      (let* ((vec (first vecs))
             (data (vec-data vec))
             (validity (vec-validity vec)))
        (cond
          ((and (typep data 'i64-vector) (key-table-native table))
           (let ((hashes (native-key-hashes data n)))
             (declare (type (simple-array (unsigned-byte 64) (*)) hashes))
             (dotimes (i n)
               (setf (aref gids i)
                     (if (and validity (zerop (sbit validity i)))
                         (int-key-null-group table add)
                         (int-key-probe-hashed table (aref data i) (aref hashes i) add))))))
          ((typep data 'i64-vector)
           (if validity
               (dotimes (i n)
                 (setf (aref gids i)
                       (if (zerop (sbit validity i))
                           (int-key-null-group table add)
                           (int-key-probe table (aref data i) add))))
               (dotimes (i n)
                 (setf (aref gids i) (int-key-probe table (aref data i) add)))))
          (t
           (dotimes (i n)
             (setf (aref gids i) (int-key-group table (vec-ref vec i) add))))))
      (let ((hashes (hash-key-vecs vecs n (key-table-native table)))
            (vecs (coerce vecs 'simple-vector))
            (width (length vecs)))
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
  gids)

(defun key-table-group-hash (table g)
  "Hash of the key of group G (used to partition groups)."
  (if (key-table-int-slots table)
      (let ((v (key-table-key table 0 g)))
        (if (eq v +null+) +null-key-hash+ (hash-i64 v)))
      (aref (key-table-hashes table) g)))

(defun key-table-intern-group (table other g)
  "Group id in TABLE of the key of group G of the key table OTHER (added if
new); both tables have the same key kinds."
  (if (key-table-int-slots table)
      (int-key-group table (key-table-key other 0 g) t)
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
                                              (lambda (k) (svref (svref other-keys k) g)))))))
