;;;; kernels.lisp — micro-benchmark: the engine's Lisp loops versus the
;;;; native kernels called through sb-alien (development aid).
;;;;
;;;; sbcl --dynamic-space-size 8192 --non-interactive --load bench/kernels.lisp LIBPQKERNELS [N]
;;;;
;;;; For batches of N rows (default 2048, the executor's batch size) it
;;;; reports nanoseconds per row of each operation done the way the engine
;;;; does it without native kernels (typed SBCL loops, exact integer sums)
;;;; and with the FFI wrappers of src/native/kernels.lisp (including the
;;;; per-call overhead: pinning, foreign call, result conversion).

(require :asdf)

(defparameter *root* (merge-pathnames "../" (make-pathname :name nil :type nil
                                                           :defaults *load-truename*)))
(asdf:initialize-output-translations
 `(:output-translations
   :ignore-inherited-configuration
   ((,(namestring (truename *root*)) :**/ :*.*.*)
    (,(namestring (merge-pathnames "build/fasl/" (truename *root*))) :**/ :*.*.*))))
(asdf:load-asd (merge-pathnames "polyquery.asd" (truename *root*)))
(asdf:load-system "polyquery")

(in-package #:polyquery)

(defun ns-per-row (n fn)
  "Median over 7 rounds of the time per row of calling FN on N rows."
  (declare (type function fn))
  (let* ((reps (max 1 (floor 400000000 (max n 1))))
         (samples (loop repeat 7
                        collect (let ((start (get-internal-real-time)))
                                  (dotimes (i reps) (funcall fn))
                                  (/ (* (- (get-internal-real-time) start)
                                        (/ 1d9 internal-time-units-per-second))
                                     (* reps n))))))
    (nth 3 (sort samples #'<))))

(defun lisp-filter (data n c out)
  (declare (type i64-vector data) (type fixnum n) (type (signed-byte 64) c)
           (type index-vector out) (optimize speed))
  (let ((m 0))
    (declare (type fixnum m))
    (dotimes (i n m)
      (when (> (aref data i) c)
        (setf (aref out m) i)
        (incf m)))))

(defun lisp-filter-bitmap (data n c bits)
  (declare (type i64-vector data) (type fixnum n) (type (signed-byte 64) c)
           (type simple-bit-vector bits) (optimize speed))
  (dotimes (i n bits)
    (setf (sbit bits i) (if (> (aref data i) c) 1 0))))

(defun lisp-compare (a b n bits)
  (declare (type i64-vector a b) (type fixnum n) (type simple-bit-vector bits) (optimize speed))
  (dotimes (i n bits)
    (setf (sbit bits i) (if (< (aref a i) (aref b i)) 1 0))))

(defun lisp-popcount (bits n)
  (declare (type simple-bit-vector bits) (type fixnum n) (optimize speed))
  (count 1 bits :end n))

(defun lisp-sum (data validity n)
  (declare (type i64-vector data) (type simple-bit-vector validity) (type fixnum n)
           (optimize speed))
  (let ((s 0))
    (declare (type integer s))
    (dotimes (i n s)
      (unless (zerop (sbit validity i)) (setf s (+ s (aref data i)))))))

(defun lisp-minmax (data n)
  (declare (type i64-vector data) (type fixnum n) (optimize speed))
  (let ((lo (aref data 0)) (hi (aref data 0)))
    (dotimes (i n (values lo hi))
      (let ((v (aref data i)))
        (when (< v lo) (setf lo v))
        (when (> v hi) (setf hi v))))))

(defun lisp-hash (data n out)
  (declare (type i64-vector data) (type fixnum n) (type index-vector out) (optimize speed))
  (dotimes (i n out)
    (setf (aref out i) (hash-i64 (aref data i)))))

(defun lisp-gather (data idx m out)
  (declare (type i64-vector data out) (type index-vector idx) (type fixnum m) (optimize speed))
  (dotimes (j m out)
    (setf (aref out j) (aref data (aref idx j)))))

(destructuring-bind (library &optional (n-text "2048")) (rest (member "--" sb-ext:*posix-argv*
                                                                      :test #'string=))
  (unless (load-native-kernels library)
    (error "cannot load ~A" library))
  (let* ((n (parse-integer n-text))
         (state (sb-ext:seed-random-state 1))
         (data (let ((v (make-array n :element-type '(signed-byte 64))))
                 (dotimes (i n v) (setf (aref v i) (- (random 2000000 state) 1000000)))))
         (other (copy-seq data))
         (validity (let ((b (make-array n :element-type 'bit)))
                     (dotimes (i n b) (setf (sbit b i) (if (< (random 10 state) 9) 1 0)))))
         (bits (make-array n :element-type 'bit))
         (idx (make-array n :element-type 'fixnum))
         (idx32 (make-array n :element-type '(unsigned-byte 32)))
         (hashes (make-array n :element-type 'fixnum))
         (hashes64 (make-array n :element-type '(unsigned-byte 64)))
         (out (make-array n :element-type '(signed-byte 64)))
         (gids (let ((v (make-array n :element-type 'fixnum)))
                 (dotimes (i n v) (setf (aref v i) (random 1024 state)))))
         (gids32 (map '(simple-array (unsigned-byte 32) (*)) #'identity gids))
         (sum-state (make-agg-state (make-b-agg :int64 :sum (list (make-b-column :int64 0 nil)) nil)))
         (vec (make-vec data validity))
         (cut (- (floor (* 2 1000000) 10) 1000000)))  ; ~10% of the rows pass
    (setf (aref other 0) 0)
    (agg-reserve sum-state 1024)
    (dotimes (i n) (setf (aref idx i) (random n state) (aref idx32 i) (aref idx i)))
    (format t "~&rows per call: ~D, variant ~A~%~%" n (native-library-variant *native-library*))
    (format t "~&| operation | Lisp ns/row | native ns/row | speed-up |~%|---|---|---|---|~%")
    (flet ((row (name lisp native)
             (let ((l (ns-per-row n lisp)) (k (ns-per-row n native)))
               (format t "| ~A | ~,3F | ~,3F | ~,1F× |~%" name l k (/ l k)))))
      (row "filter x > c → selection (10%)"
           (lambda () (lisp-filter data n (- cut) idx))
           (lambda () (native-filter-i64 data nil n +pqk-gt+ (- cut) 0 idx32)))
      (row "filter x > c → bitmap (bit-vector)"
           (lambda () (lisp-filter-bitmap data n cut bits))
           (lambda () (native-filter-i64-bitmap data nil n +pqk-gt+ cut 0 bits)))
      (row "exact SUM with validity"
           (lambda () (lisp-sum data validity n))
           (lambda () (native-sum-i64 data validity n)))
      (row "MIN/MAX"
           (lambda () (lisp-minmax data n))
           (lambda () (native-minmax-i64 data nil n)))
      (row "COUNT(x) (popcount of validity)"
           (lambda () (lisp-popcount validity n))
           (lambda () (native-popcount validity n)))
      (row "hash (murmur3 fmix64)"
           (lambda () (lisp-hash data n hashes))
           (lambda () (native-hash-i64 data n hashes64)))
      (row "grouped SUM, 1024 groups (sum state)"
           (lambda () (agg-update sum-state gids vec n))
           (lambda () (agg-update-native sum-state gids (lambda () gids32) vec n)))
      (row "gather by selection"
           (lambda () (lisp-gather data idx n out))
           (lambda () (native-gather data idx32 n out)))
      (row "compare x < y → bitmap"
           (lambda () (lisp-compare data other n bits))
           (lambda () (native-compare-i64 data other n +pqk-lt+ bits))))))
