;;;; test-sort.lisp — radix sort of normalized ORDER BY keys (vsort.lisp)
;;;; against the stable comparison sort.

(in-package #:polyquery-tests)

(defun random-sort-string (state)
  "Short strings with shared prefixes, long ones (beyond the prefix words),
characters above 254, NUL characters and empty strings."
  (let ((len (case (random 4 state) (0 (random 3 state)) (1 (random 9 state)) (t (random 24 state)))))
    (coerce (loop for k below len
                  collect (case (random 40 state)
                            (0 (code-char 0))
                            (1 (code-char 255))
                            (2 (code-char (+ 256 (random 3 state))))
                            (3 (code-char 954))
                            (t (if (< k 10) #\a (code-char (+ 97 (random 3 state)))))))
            'string)))

(defun random-sort-batch (n state)
  "Batch of N rows: INT64, FLOAT64 (with -0.0), STRING, BOOLEAN and a wide
DECIMAL column, all with NULLs."
  (flet ((maybe-null (v) (if (zerop (random 7 state)) polyquery::+null+ v)))
    (let ((ints (loop repeat n collect (maybe-null (- (random 21 state) 10))))
          (floats (loop repeat n collect (maybe-null (case (random 5 state)
                                                       (0 -0d0) (1 0d0)
                                                       (t (- (random 9 state) 4.5d0))))))
          (strings (loop repeat n collect (maybe-null (random-sort-string state))))
          (bools (loop repeat n collect (maybe-null (zerop (random 2 state)))))
          (wides (loop repeat n collect (maybe-null (- (random 7 state) 3)))))
      (polyquery::make-batch
       n (vector (polyquery::build-vec :i64 n (lambda (i) (nth i ints)))
                 (polyquery::build-vec :f64 n (lambda (i) (nth i floats)))
                 (polyquery::build-vec :any n (lambda (i) (nth i strings)))
                 (polyquery::build-vec :any n (lambda (i) (nth i bools)))
                 (polyquery::build-vec :any n (lambda (i) (nth i wides))))))))

(defparameter *sort-column-types*
  (vector :int64 :float64 :string :boolean (polyquery::make-decimal-type 30 0)))

(defun radix-matches-comparison-sort-p (batch keys threads)
  (let* ((before (polyquery::make-index-sort-predicate batch keys))
         (expected (stable-sort (polyquery::identity-index-vector (polyquery::batch-count batch))
                                before))
         (actual (let ((polyquery::*morsel-rows* 64))
                   (polyquery::radix-sorted-permutation batch keys before threads))))
    (and actual (equalp expected actual))))

(deftest sort.radix-matches-comparison-sort
    (let ((state (sb-ext:seed-random-state 42))
          (failures '()))
      (dotimes (trial 60)
        (let* ((n (+ 1 (random 3000 state)))
               (batch (random-sort-batch n state))
               (keys (loop repeat (1+ (random 3 state))
                           collect (let ((pos (random 5 state)))
                                     (list pos (svref *sort-column-types* pos)
                                           (zerop (random 2 state)) (zerop (random 2 state)))))))
          (dolist (threads '(1 4))
            (unless (radix-matches-comparison-sort-p batch keys threads)
              (push (list trial threads keys) failures)))))
      failures)
  nil)

(deftest sort.radix-strings-beyond-prefix
    ;; Equal 16-character prefixes: the order is decided by the full comparison.
    (let* ((strings (vector "aaaaaaaaaaaaaaaaz" "aaaaaaaaaaaaaaaab" "aaaaaaaaaaaaaaaa"
                            "aaaaaaaaaaaaaaaaab" "b" "" "aaaaaaaaaaaaaaaab"))
           (n (length strings))
           (batch (polyquery::make-batch
                   n (vector (polyquery::build-vec :any n (lambda (i) (svref strings i)))
                             (polyquery::build-vec :i64 n (lambda (i) (- i))))))
           (keys (list (list 0 :string nil nil))))
      (let ((polyquery::*string-key-max-words* 2))
        (list (coerce (polyquery::radix-sorted-permutation
                       batch keys (polyquery::make-index-sort-predicate batch keys) 1)
                      'list)
              (radix-matches-comparison-sort-p batch (list (list 0 :string t nil) (list 1 :int64 nil nil)) 1))))
  ((5 2 3 1 6 0 4) t))

(deftest sort.radix-unsupported-key
    ;; Wide DECIMAL values beyond 64 bits fall back to the comparison sort.
    (let* ((n 3)
           (batch (polyquery::make-batch
                   n (vector (polyquery::build-vec :any n (lambda (i) (* (expt 10 30) (- 2 i))))))))
      (polyquery::radix-sorted-permutation
       batch (list (list 0 (polyquery::make-decimal-type 38 0) nil nil))
       (constantly nil) 1))
  nil)
