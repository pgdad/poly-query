;;;; vectors.lisp — column vectors and batches for the vectorized executor.
;;;;
;;;; A BATCH holds up to +BATCH-SIZE+ rows as one VEC per column. The physical
;;;; representation of a VEC follows the static type of its column (its
;;;; *kind*, see TYPE-VEC-KIND):
;;;;   :I64  INT64, DECIMAL (unscaled), DATE (days), TIMESTAMP (micros) in a
;;;;         (SIGNED-BYTE 64) vector plus a validity bitmap (1 = non-NULL; NIL
;;;;         when no value is NULL) — the same layout as the column stores, so
;;;;         scans copy whole slices and kernels run tight typed loops;
;;;;   :F64  FLOAT64 in a DOUBLE-FLOAT vector plus a validity bitmap;
;;;;   :ANY  every other type (BOOLEAN, STRING, the NULL type) as a
;;;;         SIMPLE-VECTOR of runtime values, NULL being :NULL.
;;;; Vectors are immutable once built: kernels never modify their inputs, so
;;;; batches, gathered copies and materialized inputs may share them.

(in-package #:polyquery)

(defconstant +batch-size+ 2048
  "Rows per batch: large enough to amortize per-batch dispatch, small enough
for a batch's vectors to stay in the CPU caches.")

(deftype index-vector () '(simple-array fixnum (*)))

(defstruct (vec (:constructor make-vec (data &optional validity codes dict)))
  data                                   ; I64-VECTOR, F64-VECTOR or SIMPLE-VECTOR
  (validity nil :type (or null simple-bit-vector))
  ;; STRING values read from a dictionary-encoded column also keep their
  ;; codes into the column's DICT-COLUMN store, so predicates can be
  ;; evaluated (and keys hashed) once per distinct value.
  (codes nil :type (or null u32-vector))
  (dict nil))

(defstruct (batch (:constructor make-batch (count columns))
                  (:constructor make-lazy-batch (count columns source)))
  (count 0 :type fixnum)
  (columns #() :type simple-vector)      ; of VEC (NIL for columns a kernel never reads)
  ;; A *lazy* batch of a TableScan read by a native filter (vnative.lisp)
  ;; has no column vectors yet, only the SCAN-SOURCE of its rows.
  (source nil))

(defun type-vec-kind (type)
  (case (type-kind type)
    ((:int64 :decimal :date :timestamp) :i64)
    (:float64 :f64)
    (t :any)))

(defun column-kinds (columns)
  "Vector kinds of a list of COLUMN-DEFs."
  (map 'simple-vector (lambda (c) (type-vec-kind (column-def-type c))) columns))

(defun make-index-vector (n)
  (make-array n :element-type 'fixnum))

(defun make-validity (n)
  (make-array n :element-type 'bit :initial-element 1))

;;; ------------------------------------------------------------------
;;; Element access (used by the generic, element-at-a-time paths)

(declaim (inline vec-ref))
(defun vec-ref (vec i)
  "Runtime value of row I of VEC."
  (declare (type fixnum i))
  (let ((data (vec-data vec))
        (validity (vec-validity vec)))
    (if (and validity (zerop (sbit validity i)))
        +null+
        (typecase data
          (i64-vector (aref data i))
          (f64-vector (aref data i))
          (t (svref data i))))))

(defun vec-length (vec)
  (length (vec-data vec)))

(defun vec-has-nulls-p (vec n)
  "True if some of the first N values of VEC are NULL."
  (let ((data (vec-data vec))
        (validity (vec-validity vec)))
    (if (simple-vector-p data)
        (find +null+ data :end n)
        (and validity (find 0 validity :end n)))))

;;; ------------------------------------------------------------------
;;; Construction

(defun build-vec (kind n fn)
  "VEC of KIND with N values (funcall FN i)."
  (declare (type fixnum n) (type function fn))
  (ecase kind
    (:i64
     (let ((data (make-array n :element-type '(signed-byte 64)))
           (validity nil))
       (dotimes (i n)
         (let ((v (funcall fn i)))
           (if (eq v +null+)
               (progn (unless validity (setf validity (make-validity n)))
                      (setf (sbit validity i) 0))
               (setf (aref data i) v))))
       (make-vec data validity)))
    (:f64
     (let ((data (make-array n :element-type 'double-float :initial-element 0d0))
           (validity nil))
       (dotimes (i n)
         (let ((v (funcall fn i)))
           (if (eq v +null+)
               (progn (unless validity (setf validity (make-validity n)))
                      (setf (sbit validity i) 0))
               (setf (aref data i) v))))
       (make-vec data validity)))
    (:any
     (let ((data (make-array n)))
       (dotimes (i n)
         (setf (svref data i) (funcall fn i)))
       (make-vec data)))))

(defun vec-from-values (kind values n)
  "VEC of KIND holding the first N runtime values of the SIMPLE-VECTOR VALUES."
  (declare (type simple-vector values))
  (if (eq kind :any)
      (make-vec (if (= n (length values)) values (subseq values 0 n)))
      (build-vec kind n (lambda (i) (svref values i)))))

(defun constant-vec (kind value n)
  "VEC of N copies of VALUE."
  (if (eq value +null+)
      (null-vec kind n)
      (ecase kind
        (:i64 (make-vec (make-array n :element-type '(signed-byte 64) :initial-element value)))
        (:f64 (make-vec (make-array n :element-type 'double-float :initial-element value)))
        (:any (make-vec (make-array n :initial-element value))))))

(defun null-vec (kind n)
  "VEC of N NULLs."
  (ecase kind
    (:i64 (make-vec (make-array n :element-type '(signed-byte 64) :initial-element 0)
                    (make-array n :element-type 'bit :initial-element 0)))
    (:f64 (make-vec (make-array n :element-type 'double-float :initial-element 0d0)
                    (make-array n :element-type 'bit :initial-element 0)))
    (:any (make-vec (make-array n :initial-element +null+)))))

(defun and-validity (a b)
  "Validity of a value that is NULL when either input is NULL."
  (cond ((null a) b)
        ((null b) a)
        (t (bit-and a b))))

;;; ------------------------------------------------------------------
;;; Gather, scatter, slice, concatenate

(defun vec-gather (vec idx n)
  "VEC of the rows IDX[0..N) of VEC; an index of -1 yields NULL."
  (declare (type index-vector idx) (type fixnum n))
  (let* ((data (vec-data vec))
         (src-validity (vec-validity vec))
         (validity nil))
    (declare (type (or null simple-bit-vector) src-validity))
    (macrolet ((gather (element-type filler accessor)
                 `(let ((out (make-array n :element-type ',element-type)))
                    (dotimes (k n)
                      (let ((i (aref idx k)))
                        (cond ((< i 0)
                               (unless validity (setf validity (make-validity n)))
                               (setf (sbit validity k) 0
                                     (,accessor out k) ,filler))
                              (t
                               (setf (,accessor out k) (,accessor data i))
                               (when (and src-validity (zerop (sbit src-validity i)))
                                 (unless validity (setf validity (make-validity n)))
                                 (setf (sbit validity k) 0))))))
                    (make-vec out validity))))
      (etypecase data
        (i64-vector (gather (signed-byte 64) 0 aref))
        (f64-vector (gather double-float 0d0 aref))
        (simple-vector
         (let ((out (make-array n))
               (codes (vec-codes vec))
               (out-codes nil))
           (dotimes (k n)
             (let ((i (aref idx k)))
               (setf (svref out k) (if (< i 0) +null+ (svref data i)))))
           (when codes
             (setf out-codes (make-array n :element-type '(unsigned-byte 32) :initial-element 0))
             (dotimes (k n)
               (let ((i (aref idx k)))
                 (unless (< i 0) (setf (aref out-codes k) (aref codes i))))))
           (make-vec out nil out-codes (and codes (vec-dict vec)))))))))

(defun vec-scatter (vec idx m n kind)
  "VEC of N rows holding row K of VEC at position IDX[K] (K < M) and NULL
everywhere else."
  (declare (type index-vector idx) (type fixnum m n))
  (if (and (= m n) (eq kind (vec-actual-kind vec)))
      vec                                ; IDX is the identity
      (let ((values (make-array n :initial-element +null+)))
        (dotimes (k m)
          (setf (svref values (aref idx k)) (vec-ref vec k)))
        (vec-from-values kind values n))))

(defun vec-actual-kind (vec)
  (etypecase (vec-data vec)
    (i64-vector :i64)
    (f64-vector :f64)
    (simple-vector :any)))

(defun vec-slice (vec start end)
  (let ((validity (vec-validity vec))
        (codes (vec-codes vec)))
    (make-vec (subseq (vec-data vec) start end)
              (and validity (subseq validity start end))
              (and codes (subseq codes start end))
              (vec-dict vec))))

(defun vec-concatenate (vecs kind total)
  "One VEC of KIND holding the values of the VECS (TOTAL rows) in order."
  (declare (type fixnum total))
  (let ((data (ecase kind
                (:i64 (make-array total :element-type '(signed-byte 64)))
                (:f64 (make-array total :element-type 'double-float :initial-element 0d0))
                (:any (make-array total))))
        (validity (when (some #'vec-validity vecs) (make-validity total)))
        (pos 0))
    (declare (type fixnum pos))
    (dolist (v vecs)
      (let ((n (vec-length v)))
        (replace data (vec-data v) :start1 pos)
        (when (vec-validity v)
          (replace validity (vec-validity v) :start1 pos))
        (incf pos n)))
    (make-vec data validity)))

(defun batch-gather (batch idx n)
  "Batch of the rows IDX[0..N) of BATCH (-1 yields a row of NULLs)."
  (make-batch n (map 'simple-vector (lambda (v) (and v (vec-gather v idx n)))
                     (batch-columns batch))))

(defun batch-slice (batch start end)
  (make-batch (- end start)
              (map 'simple-vector (lambda (v) (and v (vec-slice v start end)))
                   (batch-columns batch))))

(defun batch-row (batch i)
  "Row I of BATCH as a fresh SIMPLE-VECTOR."
  (let* ((columns (batch-columns batch))
         (row (make-array (length columns))))
    (dotimes (k (length columns) row)
      (setf (svref row k) (vec-ref (svref columns k) i)))))

(defun identity-index-vector (n)
  (let ((idx (make-index-vector n)))
    (dotimes (i n idx) (setf (aref idx i) i))))

;;; ------------------------------------------------------------------
;;; Selections

(defun true-indices (vec n)
  "(values indices count) of the rows among the first N whose BOOLEAN value is TRUE."
  (declare (type fixnum n))
  (let ((data (vec-data vec))
        (idx (make-index-vector n))
        (m 0))
    (declare (type simple-vector data) (type fixnum m))
    (dotimes (i n)
      (when (eq (svref data i) t)
        (setf (aref idx m) i)
        (incf m)))
    (values idx m)))

(defun filter-batch (batch vec)
  "The rows of BATCH whose value in the BOOLEAN VEC is TRUE (BATCH itself when
all are; NIL when none is)."
  (let ((n (batch-count batch)))
    (multiple-value-bind (idx m) (true-indices vec n)
      (cond ((= m n) batch)
            ((zerop m) nil)
            (t (batch-gather batch idx m))))))

;;; ------------------------------------------------------------------
;;; Batches <-> rows

(defun batches-to-rows-opener (open-batches)
  "Row opener (see COMPILE-OPERATOR) producing the rows of a batch opener."
  (declare (type function open-batches))
  (lambda ()
    (let ((next-batch (funcall open-batches))
          (batch nil)
          (i 0) (n 0))
      (declare (type function next-batch) (type fixnum i n))
      (lambda ()
        (loop
          (when (< i n)
            (return (prog1 (batch-row batch i) (incf i))))
          (setf batch (funcall next-batch))
          (unless batch (return nil))
          (setf i 0 n (batch-count batch)))))))

(defun rows-to-batch (rows n kinds)
  "Batch of the first N row vectors of ROWS (column kinds KINDS)."
  (declare (type simple-vector rows kinds) (type fixnum n))
  (make-batch n (let ((columns (make-array (length kinds))))
                  (dotimes (k (length kinds) columns)
                    (let ((k k))
                      (setf (svref columns k)
                            (build-vec (svref kinds k) n
                                       (lambda (i) (svref (svref rows i) k)))))))))

(defun rows-to-batches-opener (open-rows kinds)
  "Batch opener producing the rows of a row opener in batches."
  (declare (type function open-rows))
  (lambda ()
    (let ((next-row (funcall open-rows))
          (done nil))
      (declare (type function next-row))
      (lambda ()
        (unless done
          (let ((rows (make-array +batch-size+))
                (n 0))
            (declare (type fixnum n))
            (loop while (< n +batch-size+)
                  do (let ((row (funcall next-row)))
                       (unless row (setf done t) (return))
                       (setf (svref rows n) row)
                       (incf n)))
            (when (plusp n)
              (rows-to-batch rows n kinds))))))))

;;; ------------------------------------------------------------------
;;; Reading storage segments

(defun store-vec (store start end kind)
  "VEC of rows [START, END) of the column store STORE, of KIND."
  (let* ((n (- end start))
         (validity (column-store-validity store))
         (vslice (and validity (subseq validity start end))))
    (cond
      ((and (eq kind :i64) (int-column-p store))
       (make-vec (subseq (int-column-values store) start end) vslice))
      ((and (eq kind :f64) (float-column-p store))
       (make-vec (subseq (float-column-values store) start end) vslice))
      ((and (eq kind :any) (string-column-p store))
       (let ((values (subseq (string-column-values store) start end)))
         (when vslice
           (dotimes (i n) (when (zerop (sbit vslice i)) (setf (svref values i) +null+))))
         (make-vec values)))
      ((and (eq kind :any) (dict-column-p store))
       (let* ((codes (subseq (dict-column-codes store) start end))
              (dict (dict-column-dictionary store))
              (out (make-array n)))
         (declare (type u32-vector codes) (type simple-vector dict))
         (dotimes (i n)
           (setf (svref out i)
                 (if (and vslice (zerop (sbit vslice i)))
                     +null+
                     (svref dict (aref codes i)))))
         (make-vec out nil codes store)))
      (t
       (let ((read (column-reader store)))
         (declare (type function read))
         (build-vec kind n (lambda (i) (funcall read (+ start i)))))))))

(defun segment-vec (segment k start end kind)
  "VEC of column K for the rows [START, END) of SEGMENT."
  (declare (type fixnum start end))
  (let ((rows (segment-rows segment)))
    (if rows
        (let ((rows rows))
          (declare (type simple-vector rows))
          (build-vec kind (- end start) (lambda (i) (svref (svref rows (+ start i)) k))))
        (store-vec (segment-column segment k) start end kind))))
