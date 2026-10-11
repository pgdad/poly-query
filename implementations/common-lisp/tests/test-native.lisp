;;;; test-native.lisp — native kernel integration (libpqkernels through
;;;; sb-alien): the FFI wrappers against Lisp reference computations, and
;;;; queries with native: true against the same queries without.
;;;;
;;;; The library is looked up in $POLYQUERY_NATIVE_KERNELS, else in
;;;; native-kernels/build/x86_64/ of the workspace (`make -C native-kernels`).
;;;; Without it these tests check nothing (native kernels are optional).

(in-package #:polyquery-tests)

(defun native-library-path ()
  (let ((env (sb-posix:getenv "POLYQUERY_NATIVE_KERNELS")))
    (if (and env (plusp (length env)))
        env
        (namestring (merge-pathnames "../../native-kernels/build/x86_64/libpqkernels.so"
                                     (asdf:system-source-directory "polyquery"))))))

(defvar *native-state* :unknown)

(defun native-available-p ()
  "Load the kernel library once; true if it is usable."
  (when (eq *native-state* :unknown)
    (setf *native-state*
          (and (probe-file (native-library-path))
               (polyquery::load-native-kernels (native-library-path))
               t))
    (unless *native-state*
      (format t "~&;; native kernel library not found (~A): native tests skipped~%"
              (native-library-path))))
  *native-state*)

(defmacro with-native (&body body)
  "BODY's value, or T when the library is not available."
  `(if (native-available-p) (progn ,@body) t))

(defun random-i64-vector (n state &optional (range (expt 2 64)))
  (let ((v (make-array n :element-type '(signed-byte 64))))
    (dotimes (i n v)
      (setf (aref v i) (- (random range state) (floor range 2))))))

(defun random-validity (n state)
  (let ((bits (make-array n :element-type 'bit)))
    (dotimes (i n bits)
      (setf (sbit bits i) (if (< (random 10 state) 2) 0 1)))))

(defun lisp-predicate (op a b)
  (ecase op
    (0 (lambda (x) (= x a))) (1 (lambda (x) (/= x a))) (2 (lambda (x) (< x a)))
    (3 (lambda (x) (<= x a))) (4 (lambda (x) (> x a))) (5 (lambda (x) (>= x a)))
    (6 (lambda (x) (<= a x b)))))

(deftest native.filter-kernels
    (with-native
      (let ((state (sb-ext:seed-random-state 42)))
        (loop for n in '(0 1 7 64 65 1000 2048)
              always
              (loop for op from 0 to 6
                    always
                    (let* ((data (random-i64-vector n state 20))
                           (validity (and (oddp op) (random-validity n state)))
                           (a (- (random 20 state) 10))
                           (b (+ a (random 5 state)))
                           (test (lisp-predicate op a b))
                           (expected (loop for i below n
                                           when (and (or (null validity) (= 1 (sbit validity i)))
                                                     (funcall test (aref data i)))
                                             collect i))
                           (bits (make-array n :element-type 'bit :initial-element 0))
                           (idx (make-array n :element-type '(unsigned-byte 32))))
                      (and (= (length expected)
                              (polyquery::native-filter-i64-bitmap data validity n op a b bits)
                              (polyquery::native-filter-i64 data validity n op a b idx)
                              (polyquery::native-count-i64 data validity n op a b))
                           (equal expected (coerce (subseq idx 0 (length expected)) 'list))
                           (multiple-value-bind (sel m) (polyquery::bits-selection bits n)
                             (equal expected (coerce (subseq sel 0 m) 'list)))))))))
  t)

(deftest native.sum-overflow
    (with-native
      (let* ((max most-positive-fixnum)
             (big (1- (expt 2 63)))
             (cancel (make-array 3 :element-type '(signed-byte 64)
                                   :initial-contents (list big 5 -10)))
             (over (make-array 2 :element-type '(signed-byte 64) :initial-contents (list big 1))))
        (declare (ignore max))
        (list (multiple-value-list (polyquery::native-sum-i64 cancel nil 3))
              (multiple-value-list (polyquery::native-sum-i64 over nil 2))
              ;; The invalid row is not summed.
              (multiple-value-list (polyquery::native-sum-i64 over #*10 2)))))
  ((9223372036854775802 t) (nil nil) (9223372036854775807 t)))

(deftest native.minmax-popcount-hash
    (with-native
      (let* ((state (sb-ext:seed-random-state 7))
             (data (random-i64-vector 1000 state))
             (validity (random-validity 1000 state))
             (valid (loop for i below 1000 when (= 1 (sbit validity i)) collect (aref data i)))
             (hashes (make-array 1000 :element-type '(unsigned-byte 64))))
        (polyquery::native-hash-i64 data 1000 hashes)
        (and (equal (multiple-value-list (polyquery::native-minmax-i64 data validity 1000))
                    (list (length valid) (reduce #'min valid) (reduce #'max valid)))
             (= (polyquery::native-popcount validity 1000) (count 1 validity))
             (= (polyquery::native-popcount validity 999) (count 1 validity :end 999))
             (loop for i below 1000
                   always (= (logand (aref hashes i) polyquery::+hash-mask+)
                             (polyquery::hash-i64 (aref data i)))))))
  t)

(deftest native.bitmap-ops
    (with-native
      (let* ((state (sb-ext:seed-random-state 3))
             (a (random-validity 100 state))
             (b (random-validity 100 state)))
        (and (equal (polyquery::bits-and a b 100) (bit-and a b))
             (equal (polyquery::bits-or a b 100) (bit-ior a b))
             (equal (polyquery::bits-andnot a b 100) (bit-andc2 a b)))))
  t)

(deftest native.group-sum-overflow-recovery
    ;; Group 0 wraps within a batch, group 1 overflows for good, group 2 is
    ;; ordinary: the sum state must hold exact sums in every case.
    (with-native
      (let* ((s (polyquery::make-agg-state (polyquery::make-b-agg :int64 :sum (list (polyquery::make-b-column :int64 0 nil)) nil)))
             (big (1- (expt 2 63)))
             (data (make-array 6 :element-type '(signed-byte 64)
                                 :initial-contents (list big 3 big big 7 -5)))
             (gids (make-array 6 :element-type 'fixnum :initial-contents '(0 2 0 1 2 0)))
             (gids32 (make-array 6 :element-type '(unsigned-byte 32) :initial-contents '(0 2 0 1 2 0)))
             (vec (polyquery::make-vec data)))
        (polyquery::agg-reserve s 3)
        (polyquery::agg-update-native s gids (lambda () gids32) vec 6)
        (polyquery::agg-update-native s gids (lambda () gids32) vec 6)
        (list (polyquery::sum-state-group s 0)
              (polyquery::sum-state-group s 1)
              (polyquery::sum-state-group s 2)
              (code-of (polyquery::agg-result s 0)))))
  (#.(* 2 (+ (1- (expt 2 63)) (1- (expt 2 63)) -5)) #.(* 2 (1- (expt 2 63))) 20 "NUMERIC_OVERFLOW"))

;;; Queries: native: true must give exactly the results of native: false.

(defun native-session ()
  (let ((session (phase5-session))
        (big (1- (expt 2 63))))
    (handle-request session
                    (jobj "op" "load" "table" "ext" "format" "csv"
                          ;; Group 1 and 2 sums wrap around in between but fit at the end.
                          "data" (format nil "k,v,d~%1,~D,1.5~%1,~D,-2.25~%1,~D,~%2,~D,0.0~%2,-1,-0.0~%3,7,3.0~%,~D,~%,,~%"
                                         big big (- big) (- big) big)))
    session))

(defparameter *native-queries*
  '("SELECT * FROM g WHERE amount > 500 AND grp < 7"
    "SELECT id, day FROM g WHERE day BETWEEN DATE '2024-03-01' AND DATE '2024-05-31' AND id % 3 = 0"
    "SELECT id FROM g WHERE grp IN (1, 3, 5) OR NOT (id >= 100)"
    "SELECT id FROM g WHERE grp IS NULL OR amount IS NULL"
    "SELECT id FROM g WHERE grp <> id AND NOT (grp BETWEEN 2 AND 9)"
    "SELECT id FROM g WHERE amount > 10.5 AND 100 / (grp - 3) > 0"
    "SELECT id FROM g WHERE id < 50 AND label LIKE 'a%'"
    "SELECT grp, COUNT(*), COUNT(amount), SUM(amount), AVG(id), MIN(day), MAX(ratio) FROM g GROUP BY grp"
    "SELECT COUNT(*), COUNT(grp), SUM(id), AVG(amount), MIN(ratio), MAX(ratio), MIN(id), MAX(day) FROM g WHERE flag"
    "SELECT label, SUM(id) FROM g WHERE id > 1000 GROUP BY label"
    "SELECT a.id, b.label FROM g a JOIN gr b ON a.id = b.id WHERE a.grp = 3"
    "SELECT DISTINCT grp FROM g"
    "SELECT k, SUM(v), COUNT(v) FROM ext GROUP BY k"
    "SELECT SUM(v) FROM ext WHERE k = 1"
    "SELECT SUM(v) FROM ext"
    "SELECT k, AVG(v) FROM ext WHERE v > 0 OR v < -100 GROUP BY k"
    "SELECT k, MIN(d), MAX(d) FROM ext GROUP BY k"
    "SELECT MIN(d), MAX(d), MIN(v), MAX(v) FROM ext"))

(defvar *native-session* nil)

(defun run-native (sql native threads &optional (mode :vectorized))
  (let ((*phase5-session* (or *native-session* (setf *native-session* (native-session)))))
    (run-with sql (options :mode mode :threads threads :native native))))

(deftest native.queries-identical
    (with-native
      (loop for sql in *native-queries*
            always (or (and (equal (run-native sql t 1) (run-native sql nil 1))
                            (equal (canonical (run-native sql t 4)) (canonical (run-native sql nil 1)))
                            (equal (canonical (run-native sql t 1))
                                   (canonical (run-native sql nil 1 :row))))
                       (progn (format t "~&native mismatch: ~A~%" sql) nil))))
  t)
