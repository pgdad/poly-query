;;;; columns.lisp — typed in-memory column vectors (column-oriented layout).
;;;;
;;;; A COLUMN-STORE holds the values of one column for a run of rows:
;;;;   INT-COLUMN     INT64, narrow DECIMAL (p <= 18, unscaled), DATE (days),
;;;;                  TIMESTAMP (micros) as (SIGNED-BYTE 64) vectors
;;;;   WIDE-COLUMN    wide DECIMAL (p > 18): unscaled values as a SIMPLE-VECTOR
;;;;                  of integers (fixnums or bignums; up to 38 digits)
;;;;   FLOAT-COLUMN   FLOAT64 as a DOUBLE-FLOAT vector
;;;;   BOOL-COLUMN    BOOLEAN as a bit vector (1 = true)
;;;;   STRING-COLUMN  STRING as a SIMPLE-VECTOR of strings
;;;;   DICT-COLUMN    dictionary-encoded STRING: (UNSIGNED-BYTE 32) codes into
;;;;                  a SIMPLE-VECTOR of distinct strings
;;;; plus a validity bitmap (1 = non-NULL; NIL when the column has no NULLs).
;;;; Value slots of NULL rows hold a zero/empty filler.
;;;;
;;;; Readers return the engine's runtime values (see types.lisp), so operators
;;;; never depend on the physical representation.

(in-package #:polyquery)

(deftype i64-vector () '(simple-array (signed-byte 64) (*)))
(deftype f64-vector () '(simple-array double-float (*)))
(deftype u32-vector () '(simple-array (unsigned-byte 32) (*)))

(defstruct (column-store (:constructor nil))
  (length 0 :type fixnum)
  (validity nil :type (or null simple-bit-vector)))

(defstruct (int-column (:include column-store))
  (values (make-array 0 :element-type '(signed-byte 64)) :type i64-vector))

(defstruct (wide-column (:include column-store))
  (values #() :type simple-vector))

(defstruct (float-column (:include column-store))
  (values (make-array 0 :element-type 'double-float) :type f64-vector))

(defstruct (bool-column (:include column-store))
  (values (make-array 0 :element-type 'bit) :type simple-bit-vector))

(defstruct (string-column (:include column-store))
  (values #() :type simple-vector))

(defstruct (dict-column (:include column-store))
  (codes (make-array 0 :element-type '(unsigned-byte 32)) :type u32-vector)
  (dictionary #() :type simple-vector)
  (key-hashes nil))                      ; per entry hash, cached by the executor

(defun column-null-count (store)
  (let ((v (column-store-validity store)))
    (if v (count 0 v) 0)))

(defun integer-kind-type-p (type)
  "True for types stored in INT-COLUMNs (64-bit integer representation)."
  (and (member (type-kind type) '(:int64 :decimal :date :timestamp))
       (not (wide-decimal-type-p type))))

;;; ------------------------------------------------------------------
;;; Building column stores from value vectors

(defun build-validity (values)
  "Validity bitmap of the value vector VALUES, or NIL when nothing is NULL."
  (declare (type simple-vector values))
  (when (find +null+ values)
    (let ((bits (make-array (length values) :element-type 'bit :initial-element 1)))
      (dotimes (i (length values) bits)
        (when (null-value-p (svref values i))
          (setf (sbit bits i) 0))))))

(defun dictionary-beneficial-p (values)
  "True when a STRING value vector has few enough distinct values (< n/2) for
dictionary encoding to pay off."
  (declare (type simple-vector values))
  (let ((n (length values))
        (seen (make-hash-table :test 'equal)))
    (and (>= n 16)
         (loop for v across values
               unless (null-value-p v)
                 do (setf (gethash v seen) t)
                    (when (>= (* 2 (hash-table-count seen)) n) (return nil))
               finally (return t)))))

(defun build-dict-column (values validity)
  (declare (type simple-vector values))
  (let* ((n (length values))
         (codes (make-array n :element-type '(unsigned-byte 32) :initial-element 0))
         (positions (make-hash-table :test 'equal))
         (dict (make-array 16 :adjustable t :fill-pointer 0)))
    (dotimes (i n)
      (let ((v (svref values i)))
        (unless (null-value-p v)
          (setf (aref codes i)
                (or (gethash v positions)
                    (setf (gethash v positions) (vector-push-extend v dict)))))))
    (make-dict-column :length n :validity validity :codes codes
                      :dictionary (coerce dict 'simple-vector))))

(defun build-column-store (values type &key (dictionary :auto))
  "Typed column store holding the value vector VALUES of TYPE. DICTIONARY is
T (force dictionary encoding of STRING columns), NIL (never) or :AUTO."
  (declare (type simple-vector values))
  (let* ((n (length values))
         (validity (build-validity values)))
    (ecase (if (wide-decimal-type-p type) :wide-decimal (type-kind type))
      (:wide-decimal
       (let ((out (make-array n :initial-element 0)))
         (dotimes (i n)
           (let ((v (svref values i)))
             (unless (null-value-p v) (setf (svref out i) v))))
         (make-wide-column :length n :validity validity :values out)))
      ((:int64 :decimal :date :timestamp)
       (let ((out (make-array n :element-type '(signed-byte 64) :initial-element 0)))
         (dotimes (i n)
           (let ((v (svref values i)))
             (unless (null-value-p v) (setf (aref out i) v))))
         (make-int-column :length n :validity validity :values out)))
      (:float64
       (let ((out (make-array n :element-type 'double-float :initial-element 0d0)))
         (dotimes (i n)
           (let ((v (svref values i)))
             (unless (null-value-p v) (setf (aref out i) v))))
         (make-float-column :length n :validity validity :values out)))
      (:boolean
       (let ((out (make-array n :element-type 'bit :initial-element 0)))
         (dotimes (i n)
           (when (eq (svref values i) t) (setf (sbit out i) 1)))
         (make-bool-column :length n :validity validity :values out)))
      ((:string :null)
       (if (or (eq dictionary t)
               (and (eq dictionary :auto) (dictionary-beneficial-p values)))
           (build-dict-column values validity)
           (let ((out (make-array n)))
             (dotimes (i n)
               (let ((v (svref values i)))
                 (setf (svref out i) (if (null-value-p v) "" v))))
             (make-string-column :length n :validity validity :values out)))))))

;;; ------------------------------------------------------------------
;;; Reading

(defmacro with-validity ((validity i) &body body)
  "Return NULL when row I is invalid according to VALIDITY, else BODY."
  `(if (and ,validity (zerop (sbit ,validity ,i)))
       +null+
       (progn ,@body)))

(defun column-reader (store)
  "Function (i) -> value of row I of STORE (NULL is :NULL)."
  (let ((validity (column-store-validity store)))
    (declare (type (or null simple-bit-vector) validity))
    (etypecase store
      (int-column
       (let ((vals (int-column-values store)))
         (declare (type i64-vector vals))
         (if validity
             (lambda (i) (declare (type fixnum i)) (with-validity (validity i) (aref vals i)))
             (lambda (i) (declare (type fixnum i)) (aref vals i)))))
      (wide-column
       (let ((vals (wide-column-values store)))
         (lambda (i) (declare (type fixnum i)) (with-validity (validity i) (svref vals i)))))
      (float-column
       (let ((vals (float-column-values store)))
         (declare (type f64-vector vals))
         (lambda (i) (declare (type fixnum i)) (with-validity (validity i) (aref vals i)))))
      (bool-column
       (let ((vals (bool-column-values store)))
         (declare (type simple-bit-vector vals))
         (lambda (i) (declare (type fixnum i)) (with-validity (validity i) (= 1 (sbit vals i))))))
      (string-column
       (let ((vals (string-column-values store)))
         (lambda (i) (declare (type fixnum i)) (with-validity (validity i) (svref vals i)))))
      (dict-column
       (let ((codes (dict-column-codes store))
             (dict (dict-column-dictionary store)))
         (declare (type u32-vector codes))
         (lambda (i) (declare (type fixnum i)) (with-validity (validity i) (svref dict (aref codes i)))))))))

(defun column-store-values (store)
  "All values of STORE as a SIMPLE-VECTOR."
  (let* ((n (column-store-length store))
         (out (make-array n))
         (read (column-reader store)))
    (declare (type function read))
    (dotimes (i n out)
      (setf (svref out i) (funcall read i)))))

(defun column-store-encoding-name (store)
  (etypecase store
    (int-column "int64")
    (wide-column "int128")
    (float-column "float64")
    (bool-column "bitmap")
    (string-column "plain")
    (dict-column "dictionary")))
