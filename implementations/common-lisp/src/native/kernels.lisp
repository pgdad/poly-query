;;;; kernels.lisp — FFI bindings to the native kernel library libpqkernels
;;;; (native-kernels/include/pq_kernels.h, ABI version 1) through SB-ALIEN.
;;;;
;;;; The library is optional and loaded at run time (LOAD-NATIVE-KERNELS,
;;;; from `--native-kernels PATH`), never linked into the saved executable.
;;;; Each kernel's entry point is resolved once into a global holding its
;;;; address; the Lisp wrappers call it through SAP-ALIEN with a constant
;;;; function type, which SBCL compiles into a direct foreign call (no
;;;; marshalling, no allocation). Lisp arrays are passed by pinning them and
;;;; handing out pointers to their data:
;;;;   * INT64-like vectors are (SIGNED-BYTE 64) arrays, FLOAT64 vectors
;;;;     DOUBLE-FLOAT arrays: their data is the C array;
;;;;   * validity bitmaps are SIMPLE-BIT-VECTORs, whose storage on a
;;;;     little-endian machine is exactly the ABI's LSB-first byte layout
;;;;     (row i = bit i%8 of byte i/8); NIL becomes a NULL pointer ("all
;;;;     valid"). Bit vectors are allocated in whole words, so a kernel
;;;;     writing ceil(n/8) bytes never leaves the vector's storage;
;;;;   * selection and group-id vectors are (UNSIGNED-BYTE 32) arrays.
;;;; Kernels are thread-safe after pqk_init and do not allocate, so worker
;;;; threads call them concurrently.

(in-package #:polyquery)

;;; Status codes and comparison operators of the ABI
(defconstant +pqk-ok+ 0)
(defconstant +pqk-overflow+ 1)
(defconstant +pqk-eq+ 0)
(defconstant +pqk-ne+ 1)
(defconstant +pqk-lt+ 2)
(defconstant +pqk-le+ 3)
(defconstant +pqk-gt+ 4)
(defconstant +pqk-ge+ 5)
(defconstant +pqk-between+ 6)
(defconstant +pqk-abi-version+ 1)
(defconstant +size-t-error+ (1- (expt 2 64)) "(size_t)-1")

(defstruct native-library
  (path "" :type string)
  (variant "" :type string)              ; active dispatch variant
  (available "" :type string))           ; variants usable on this CPU

(defvar *native-library* nil
  "The loaded NATIVE-LIBRARY, or NIL when no kernel library is loaded.")

(defvar *native-entry-points* '()
  "(c-name . address-symbol) of every bound kernel, resolved on load.")

(defmacro define-native-function (name c-name result-type &rest args)
  "Define the inline function NAME calling the C function C-NAME. ARGS are
(lisp-name alien-type) pairs. The address is resolved by LOAD-NATIVE-KERNELS."
  (let ((address (intern (format nil "*~A-ADDRESS*" name))))
    `(progn
       (sb-ext:defglobal ,address 0)
       (declaim (type (unsigned-byte 64) ,address))
       (pushnew '(,c-name . ,address) *native-entry-points* :test #'equal)
       (declaim (inline ,name))
       (defun ,name ,(mapcar #'first args)
         (sb-alien:alien-funcall
          (sb-alien:sap-alien (sb-sys:int-sap ,address)
                              (function ,result-type ,@(mapcar #'second args)))
          ,@(mapcar #'first args))))))

;;; Raw entry points (pointer arguments are SAPs)

(define-native-function %pqk-abi-version "pqk_abi_version" sb-alien:int)
(define-native-function %pqk-init "pqk_init" sb-alien:int)
(define-native-function %pqk-variant "pqk_variant" sb-alien:c-string)
(define-native-function %pqk-available-variants "pqk_available_variants" sb-alien:c-string)

(define-native-function %pqk-filter-i64 "pqk_filter_i64" sb-alien:unsigned-long
  (data sb-sys:system-area-pointer) (validity sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long) (op sb-alien:int)
  (a (sb-alien:signed 64)) (b (sb-alien:signed 64))
  (out sb-sys:system-area-pointer))

(define-native-function %pqk-filter-i64-bitmap "pqk_filter_i64_bitmap" sb-alien:unsigned-long
  (data sb-sys:system-area-pointer) (validity sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long) (op sb-alien:int)
  (a (sb-alien:signed 64)) (b (sb-alien:signed 64))
  (out sb-sys:system-area-pointer))

(define-native-function %pqk-sum-i64 "pqk_sum_i64" sb-alien:int
  (data sb-sys:system-area-pointer) (validity sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long) (out sb-sys:system-area-pointer))

(define-native-function %pqk-minmax-i64 "pqk_minmax_i64" sb-alien:unsigned-long
  (data sb-sys:system-area-pointer) (validity sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long)
  (out-min sb-sys:system-area-pointer) (out-max sb-sys:system-area-pointer))

(define-native-function %pqk-minmax-f64 "pqk_minmax_f64" sb-alien:unsigned-long
  (data sb-sys:system-area-pointer) (validity sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long)
  (out-min sb-sys:system-area-pointer) (out-max sb-sys:system-area-pointer))

(define-native-function %pqk-count-i64 "pqk_count_i64" sb-alien:unsigned-long
  (data sb-sys:system-area-pointer) (validity sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long) (op sb-alien:int)
  (a (sb-alien:signed 64)) (b (sb-alien:signed 64)))

(define-native-function %pqk-bitmap-and "pqk_bitmap_and" sb-alien:void
  (a sb-sys:system-area-pointer) (b sb-sys:system-area-pointer)
  (out sb-sys:system-area-pointer) (nbytes sb-alien:unsigned-long))

(define-native-function %pqk-bitmap-or "pqk_bitmap_or" sb-alien:void
  (a sb-sys:system-area-pointer) (b sb-sys:system-area-pointer)
  (out sb-sys:system-area-pointer) (nbytes sb-alien:unsigned-long))

(define-native-function %pqk-bitmap-andnot "pqk_bitmap_andnot" sb-alien:void
  (a sb-sys:system-area-pointer) (b sb-sys:system-area-pointer)
  (out sb-sys:system-area-pointer) (nbytes sb-alien:unsigned-long))

(define-native-function %pqk-bitmap-popcount "pqk_bitmap_popcount" sb-alien:unsigned-long
  (bits sb-sys:system-area-pointer) (nbits sb-alien:unsigned-long))

(define-native-function %pqk-hash-i64 "pqk_hash_i64" sb-alien:void
  (data sb-sys:system-area-pointer) (n sb-alien:unsigned-long)
  (seed (sb-alien:unsigned 64)) (out sb-sys:system-area-pointer))

(define-native-function %pqk-compare-i64 "pqk_compare_i64" sb-alien:unsigned-long
  (a sb-sys:system-area-pointer) (b sb-sys:system-area-pointer)
  (n sb-alien:unsigned-long) (op sb-alien:int) (out sb-sys:system-area-pointer))

(define-native-function %pqk-group-sum-i64 "pqk_group_sum_i64" sb-alien:int
  (gids sb-sys:system-area-pointer) (values sb-sys:system-area-pointer)
  (validity sb-sys:system-area-pointer) (n sb-alien:unsigned-long)
  (sums sb-sys:system-area-pointer) (counts sb-sys:system-area-pointer)
  (ngroups sb-alien:unsigned-long))

(define-native-function %pqk-gather-i64 "pqk_gather_i64" sb-alien:void
  (data sb-sys:system-area-pointer) (idx sb-sys:system-area-pointer)
  (m sb-alien:unsigned-long) (out sb-sys:system-area-pointer))

;;; ------------------------------------------------------------------
;;; Loading

(defun load-native-kernels (path)
  "Load the kernel library at PATH and select its variant. Returns the
NATIVE-LIBRARY, or (values NIL message) when it cannot be used (the engine
then runs its own code paths)."
  (handler-case
      (progn
        (sb-alien:load-shared-object (sb-ext:native-pathname path) :dont-save t)
        (let ((missing '()))
          (loop for (c-name . address) in *native-entry-points*
                do (let ((a (sb-sys:find-foreign-symbol-address c-name)))
                     (if a
                         (setf (symbol-value address) a)
                         (push c-name missing))))
          (cond
            (missing
             (values nil (format nil "~A lacks ~{~A~^, ~}" path missing)))
            ((/= (%pqk-abi-version) +pqk-abi-version+)
             (values nil (format nil "~A has ABI version ~D, expected ~D"
                                 path (%pqk-abi-version) +pqk-abi-version+)))
            ((/= (%pqk-init) +pqk-ok+)
             (values nil (format nil "pqk_init failed for ~A" path)))
            (t
             (setf *native-library*
                   (make-native-library :path path
                                        :variant (%pqk-variant)
                                        :available (%pqk-available-variants)))))))
    (error (e)
      (values nil (format nil "cannot load ~A: ~A" path e)))))

(declaim (inline native-loaded-p))
(defun native-loaded-p ()
  (not (null *native-library*)))

(defun native-kernels-enabled-p (&optional (settings *execution-settings*))
  "True when the statement being compiled uses the native kernels (as the
physical planner decided: the library is loaded and the query asked for them
with option native: true)."
  (and *native-library* (execution-settings-native settings) t))

;;; ------------------------------------------------------------------
;;; Array-level wrappers

(defmacro with-data-pointers (bindings &body body)
  "Bind each VAR of BINDINGS ((var array-form) ...) to a SAP to the data of
the array (a NULL pointer for NIL), keeping the arrays pinned during BODY."
  (let ((temps (mapcar (lambda (b) (declare (ignore b)) (gensym "ARRAY")) bindings)))
    `(let ,(mapcar (lambda (tmp b) `(,tmp ,(second b))) temps bindings)
       (sb-sys:with-pinned-objects ,temps
         (let ,(mapcar (lambda (tmp b)
                         `(,(first b) (if ,tmp (sb-sys:vector-sap ,tmp) (sb-sys:int-sap 0))))
                       temps bindings)
           ,@body)))))

(deftype validity-bits () '(or null simple-bit-vector))

(declaim (inline element-sap))
(defun element-sap (sap offset)
  "SAP of the 8-byte element OFFSET of the array data at SAP."
  (declare (type fixnum offset))
  (sb-sys:sap+ sap (* 8 offset)))

;;; DATA arguments are read from element OFFSET on (rows i < N are
;;; DATA[OFFSET + i]), so kernels can run on a slice of a column store
;;; without copying it. Validity bitmaps always start at row 0.

(defun native-filter-i64 (data validity n op a b out &optional (offset 0))
  "Indices (into the U32-VECTOR OUT) of the valid rows i < N with
op(DATA[OFFSET+i], A, B); returns their count."
  (declare (type i64-vector data) (type validity-bits validity) (type u32-vector out)
           (type fixnum n op offset) (type (signed-byte 64) a b))
  (with-data-pointers ((d data) (v validity) (o out))
    (%pqk-filter-i64 (element-sap d offset) v n op a b o)))

(defun native-filter-i64-bitmap (data validity n op a b out &optional (offset 0))
  "Sets bit i of the bit vector OUT for the valid rows i < N with
op(DATA[OFFSET+i], A, B); returns their count."
  (declare (type i64-vector data) (type validity-bits validity) (type simple-bit-vector out)
           (type fixnum n op offset) (type (signed-byte 64) a b))
  (with-data-pointers ((d data) (v validity) (o out))
    (%pqk-filter-i64-bitmap (element-sap d offset) v n op a b o)))

(defun native-count-i64 (data validity n op a b)
  "Number of valid rows i < N with op(DATA[i], A, B)."
  (declare (type i64-vector data) (type validity-bits validity)
           (type fixnum n op) (type (signed-byte 64) a b))
  (with-data-pointers ((d data) (v validity))
    (%pqk-count-i64 d v n op a b)))

(defun native-sum-i64 (data validity n &optional (offset 0))
  "(values sum t) of the valid values among DATA[OFFSET+i], i < N, or
(values nil nil) when the exact sum does not fit 64 bits."
  (declare (type i64-vector data) (type validity-bits validity) (type fixnum n offset))
  (let ((out (make-array 1 :element-type '(signed-byte 64) :initial-element 0)))
    (declare (dynamic-extent out))
    (let ((status (with-data-pointers ((d data) (v validity) (o out))
                    (%pqk-sum-i64 (element-sap d offset) v n o))))
      (if (= status +pqk-ok+)
          (values (aref out 0) t)
          (values nil nil)))))

(defun native-minmax-i64 (data validity n &optional (offset 0))
  "(values count min max) of the valid values among DATA[OFFSET+i], i < N."
  (declare (type i64-vector data) (type validity-bits validity) (type fixnum n offset))
  (let ((out (make-array 2 :element-type '(signed-byte 64) :initial-element 0)))
    (declare (dynamic-extent out))
    (let ((count (with-data-pointers ((d data) (v validity) (o out))
                   (%pqk-minmax-i64 (element-sap d offset) v n o (sb-sys:sap+ o 8)))))
      (values count (aref out 0) (aref out 1)))))

(defun native-minmax-f64 (data validity n &optional (offset 0))
  "(values count min max) of the valid (finite) values among DATA[OFFSET+i], i < N."
  (declare (type f64-vector data) (type validity-bits validity) (type fixnum n offset))
  (let ((out (make-array 2 :element-type 'double-float :initial-element 0d0)))
    (declare (dynamic-extent out))
    (let ((count (with-data-pointers ((d data) (v validity) (o out))
                   (%pqk-minmax-f64 (element-sap d offset) v n o (sb-sys:sap+ o 8)))))
      (values count (aref out 0) (aref out 1)))))

(declaim (inline bitmap-bytes))
(defun bitmap-bytes (nbits)
  (declare (type fixnum nbits))
  (ceiling nbits 8))

(macrolet ((define-bitmap-op (name raw doc)
             `(defun ,name (a b out n)
                ,doc
                (declare (type simple-bit-vector a b out) (type fixnum n))
                (with-data-pointers ((pa a) (pb b) (po out))
                  (,raw pa pb po (bitmap-bytes n)))
                out)))
  (define-bitmap-op native-bitmap-and %pqk-bitmap-and "OUT := A AND B (first N bits, whole bytes).")
  (define-bitmap-op native-bitmap-or %pqk-bitmap-or "OUT := A OR B (first N bits, whole bytes).")
  (define-bitmap-op native-bitmap-andnot %pqk-bitmap-andnot
    "OUT := A AND NOT B (first N bits, whole bytes)."))

(defun native-popcount (bits n)
  "Number of set bits among the first N of the bit vector BITS."
  (declare (type simple-bit-vector bits) (type fixnum n))
  (with-data-pointers ((p bits))
    (%pqk-bitmap-popcount p n)))

(defun native-hash-i64 (data n out)
  "OUT[i] := murmur3 fmix64 of DATA[i] (seed 0) for i < N; OUT is a
(UNSIGNED-BYTE 64) vector."
  (declare (type i64-vector data) (type (simple-array (unsigned-byte 64) (*)) out)
           (type fixnum n))
  (with-data-pointers ((d data) (o out))
    (%pqk-hash-i64 d n 0 o))
  out)

(defun native-compare-i64 (a b n op out &optional (offset-a 0) (offset-b 0))
  "Bit i of OUT := op(A[OFFSET-A+i], B[OFFSET-B+i]) for i < N (validity not
consulted); returns the number of set bits."
  (declare (type i64-vector a b) (type simple-bit-vector out) (type fixnum n op offset-a offset-b))
  (with-data-pointers ((pa a) (pb b) (po out))
    (%pqk-compare-i64 (element-sap pa offset-a) (element-sap pb offset-b) n op po)))

(defun native-group-sum-i64 (gids values validity n sums counts ngroups)
  "Accumulate the valid VALUES[i] (i < N) into SUMS[GIDS[i]] and count them
in COUNTS[GIDS[i]] (wrapping arithmetic). Returns the kernel status:
+PQK-OK+ guarantees exact sums, +PQK-OVERFLOW+ means some addition wrapped."
  (declare (type u32-vector gids) (type i64-vector values sums counts)
           (type validity-bits validity) (type fixnum n ngroups))
  (with-data-pointers ((g gids) (v values) (b validity) (s sums) (c counts))
    (%pqk-group-sum-i64 g v b n s c ngroups)))

(defun native-gather (data idx m out &optional (offset 0))
  "OUT[j] := DATA[OFFSET+IDX[j]] for j < M. DATA and OUT are both 64-bit
integer or both DOUBLE-FLOAT vectors (the kernel copies 8-byte elements)."
  (declare (type (or i64-vector f64-vector) data out) (type u32-vector idx) (type fixnum m offset))
  (with-data-pointers ((d data) (i idx) (o out))
    (%pqk-gather-i64 (element-sap d offset) i m o))
  out)
