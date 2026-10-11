;;;; vsort.lisp — ORDER BY of large inputs by radix sort of normalized keys.
;;;;
;;;; Every ORDER BY key is encoded as one or more unsigned 64-bit *key words*
;;;; per row whose unsigned order is the key's order (NULL placement and
;;;; DESC included):
;;;;   INT64/DECIMAL/DATE/TIMESTAMP  the value with its sign bit flipped;
;;;;   FLOAT64   the IEEE-754 bits, negative values complemented, positive
;;;;             ones with the sign bit set (-0.0 is encoded as 0.0);
;;;;   BOOLEAN   0 / 1;
;;;;   STRING    big-endian prefix words of 8 characters, each character
;;;;             code clamped to 255 and the string padded with zeros (and
;;;;             cut after its first clamped character);
;;;;   DESC      complements the words of a key; a key with NULLs gets an
;;;;             extra word in front (0/1) placing them first or last.
;;;; Comparing the words of two rows lexicographically then orders them like
;;;; the comparison sort, except that string prefix words only order
;;;; strings *weakly* (a < b implies prefix(a) <= prefix(b)). A string is
;;;; *exact* when its words determine it (no code 0 or above 254, at most
;;;; 8 characters per word); runs of rows whose words are equal up to the
;;;; first string key and that contain an inexact row are re-sorted with the
;;;; full comparison predicate.
;;;;
;;;; The rows are sorted by an LSD radix sort over the words, which is
;;;; stable, so ties keep their input order exactly as the stable comparison
;;;; sort does. Digits whose value is the same in every row are skipped.
;;;; With several threads the rows are first partitioned (stably) by their
;;;; most significant varying digit; the partition is cut into one range of
;;;; whole buckets per thread and every range is radix-sorted independently.

(in-package #:polyquery)

(deftype u64-vector () '(simple-array (unsigned-byte 64) (*)))

(defconstant +radix-bits+ 11)
(defconstant +radix-buckets+ (ash 1 +radix-bits+))
(defconstant +radix-digits+ (ceiling 64 +radix-bits+))
(defconstant +u64-mask+ #xFFFFFFFFFFFFFFFF)

(defparameter *radix-sort-min-rows* 4096
  "Inputs with fewer rows are sorted by the comparison sort.")

(defparameter *string-key-max-words* 2
  "Prefix words (of 8 characters) encoded per STRING key.")

(defun make-u64-vector (n)
  (make-array n :element-type '(unsigned-byte 64) :initial-element 0))

(deftype radix-digit () `(integer 0 ,(1- +radix-digits+)))

(declaim (inline digit-of))
(defun digit-of (word d)
  (declare (type (unsigned-byte 64) word) (type radix-digit d))
  (ldb (byte +radix-bits+ (* d +radix-bits+)) word))

;;; ------------------------------------------------------------------
;;; Key encoding

(defun null-rows (vec n)
  "Bit vector (1 = NULL) of the first N rows of VEC, or NIL without NULLs."
  (let ((data (vec-data vec))
        (validity (vec-validity vec)))
    (cond ((simple-vector-p data)
           (when (find +null+ data :end n)
             (let ((nulls (make-array n :element-type 'bit :initial-element 0)))
               (dotimes (i n nulls)
                 (when (eq (svref data i) +null+) (setf (sbit nulls i) 1))))))
          ((and validity (find 0 validity :end n))
           (bit-not (subseq validity 0 n))))))

(defun null-placement-word (nulls n nulls-first)
  (let ((w (make-u64-vector n))
        (null-value (if nulls-first 0 1)))
    (declare (type simple-bit-vector nulls))
    (dotimes (i n w)
      (setf (aref w i) (if (= (sbit nulls i) 1) null-value (- 1 null-value))))))

(defun encode-i64-word (data nulls n flip)
  (declare (type i64-vector data) (type (or null simple-bit-vector) nulls)
           (type fixnum n) (type (unsigned-byte 64) flip)
           (optimize speed))
  (let ((w (make-u64-vector n)))
    (dotimes (i n w)
      (unless (and nulls (= (sbit nulls i) 1))
        (setf (aref w i) (logxor (logand (aref data i) +u64-mask+) #x8000000000000000 flip))))))

(defun encode-f64-word (data nulls n flip)
  (declare (type f64-vector data) (type (or null simple-bit-vector) nulls)
           (type fixnum n) (type (unsigned-byte 64) flip)
           (optimize speed))
  (let ((w (make-u64-vector n)))
    (dotimes (i n w)
      (unless (and nulls (= (sbit nulls i) 1))
        (let* ((x (aref data i))
               (bits (logand (sb-kernel:double-float-bits (if (= x 0d0) 0d0 x)) +u64-mask+)))
          (declare (type (unsigned-byte 64) bits))
          (setf (aref w i) (logxor (if (logbitp 63 bits)
                                       (logxor bits +u64-mask+)
                                       (logior bits #x8000000000000000))
                                   flip)))))))

(defun encode-any-integer-word (data nulls n flip)
  "Words of a SIMPLE-VECTOR of integers (wide DECIMALs), or NIL when one of
them does not fit 64 bits."
  (declare (type simple-vector data) (type fixnum n))
  (let ((w (make-u64-vector n)))
    (dotimes (i n w)
      (unless (and nulls (= (sbit nulls i) 1))
        (let ((v (svref data i)))
          (unless (typep v '(signed-byte 64))
            (return-from encode-any-integer-word nil))
          (setf (aref w i) (logxor (logand v +u64-mask+) #x8000000000000000 flip)))))))

(defun encode-boolean-word (data nulls n flip)
  (declare (type simple-vector data) (type fixnum n))
  (let ((w (make-u64-vector n)))
    (dotimes (i n w)
      (unless (and nulls (= (sbit nulls i) 1))
        (setf (aref w i) (logxor (if (svref data i) 1 0) flip))))))

(deftype inexact-flags () '(simple-array (unsigned-byte 8) (*)))

(defun make-inexact-flags (n)
  "Per-row flags (bytes, so that threads may set those of their own rows)."
  (make-array n :element-type '(unsigned-byte 8) :initial-element 0))

(defun encode-string-row (s words i flip)
  "Store the prefix words of the string S as row I of the u64 vectors WORDS
(a SIMPLE-VECTOR), complemented when FLIP is all ones. Characters are
encoded up to and including the first one with a code above 254 (clamped
to 255, it does not order the characters after it). Returns true when the
words determine S: at most 8 characters per word, no code 0 or above 254."
  (declare (type simple-vector words) (type fixnum i) (type (unsigned-byte 64) flip)
           (optimize speed))
  (let* ((count (length words))
         (limit (* 8 count))
         (exact t))
    (declare (type fixnum count limit))
    (dotimes (w count)
      (setf (aref (the u64-vector (svref words w)) i) 0))
    (macrolet ((encode (string-type)
                 `(let ((s s))
                    (declare (type ,string-type s))
                    (let ((len (length s)))
                      (when (> len limit) (setf exact nil))
                      (loop for k of-type fixnum below (min len limit)
                            do (let* ((code (char-code (schar s k)))
                                      (byte (min code 255))
                                      (word (svref words (ash k -3))))
                                 (declare (type u64-vector word))
                                 (setf (aref word i)
                                       (logior (aref word i)
                                               (logand (ash byte (- 56 (* 8 (logand k 7)))) +u64-mask+)))
                                 (when (or (zerop code) (> code 254))
                                   (setf exact nil))
                                 (when (> code 254) (return))))))))
      (typecase s
        ((simple-array character (*)) (encode (simple-array character (*))))
        (t (encode simple-string))))
    (unless (zerop flip)
      (dotimes (w count)
        (let ((word (svref words w)))
          (declare (type u64-vector word))
          (setf (aref word i) (logxor (aref word i) flip)))))
    exact))

(defun encode-string-words (data nulls n flip inexact threads)
  "Prefix words of a SIMPLE-VECTOR of strings, setting INEXACT[i] for rows
whose words do not determine their string."
  (declare (type simple-vector data) (type fixnum n) (type inexact-flags inexact)
           (type (unsigned-byte 64) flip))
  (let* ((max-length (loop for i below n
                           for v = (svref data i)
                           unless (and nulls (= (sbit nulls i) 1))
                             maximize (length (the simple-string v))))
         (count (max 1 (min *string-key-max-words* (ceiling max-length 8))))
         (words (coerce (loop repeat count collect (make-u64-vector n)) 'simple-vector)))
    (map-row-ranges n threads
                    (lambda (start end)
                      (declare (type fixnum start end))
                      (loop for i of-type fixnum from start below end
                            unless (and nulls (= (sbit nulls i) 1))
                              do (unless (encode-string-row (svref data i) words i flip)
                                   (setf (aref inexact i) 1)))))
    (coerce words 'list)))

(defun map-row-ranges (n threads fn &optional (grain (morsel-rows)))
  "Call (FN start end) on consecutive ranges covering [0, N), in up to THREADS
threads, each range holding at least GRAIN elements."
  (declare (type function fn))
  (let ((chunks (min threads (max 1 (floor n grain)))))
    (if (<= chunks 1)
        (funcall fn 0 n)
        (run-in-threads
         (loop for k below chunks
               collect (let ((start (floor (* k n) chunks))
                             (end (floor (* (1+ k) n) chunks)))
                         (lambda () (funcall fn start end))))))))

(defun encode-sort-key (vec type descending nulls-first n inexact threads)
  "(values words supported): the key words of the first N rows of VEC for one
ORDER BY key (most significant first); SUPPORTED is NIL for keys the radix
sort cannot encode. Sets INEXACT[i] for string rows needing the full
comparison."
  (let* ((data (vec-data vec))
         (nulls (null-rows vec n))
         (flip (if descending +u64-mask+ 0))
         (prefix (and nulls (list (null-placement-word nulls n nulls-first))))
         (all-null (and nulls (not (find 0 nulls)))))
    (flet ((done (words) (values (append prefix words) t)))
      (cond
        (all-null (done '()))
        ((typep data 'i64-vector) (done (list (encode-i64-word data nulls n flip))))
        ((typep data 'f64-vector) (done (list (encode-f64-word data nulls n flip))))
        ((not (simple-vector-p data)) (values nil nil))
        (t
         (case (type-kind type)
           (:string (done (encode-string-words data nulls n flip inexact threads)))
           (:boolean (done (list (encode-boolean-word data nulls n flip))))
           ((:int64 :decimal :date :timestamp)
            (let ((w (encode-any-integer-word data nulls n flip)))
              (if w (done (list w)) (values nil nil))))
           (:null (done '()))
           (t (values nil nil))))))))

(defun encode-sort-keys (batch keys n threads)
  "(values words inexact-run-words inexact): the key words of all ORDER BY
KEYS, the number of leading words through the first string key (NIL when no
row is inexact) and the inexact-row flags; NIL when some key is not
supported."
  (let ((inexact (make-inexact-flags n))
        (words '())
        (run-words nil))
    (dolist (key keys)
      (destructuring-bind (pos type descending nulls-first) key
        (multiple-value-bind (key-words supported)
            (encode-sort-key (svref (batch-columns batch) pos) type descending nulls-first n
                             inexact threads)
          (unless supported
            (return-from encode-sort-keys nil))
          (setf words (append words key-words))
          (when (and (null run-words) (eq (type-kind type) :string))
            (setf run-words (length words))))))
    (values words (and run-words (find 1 inexact) run-words) inexact)))

;;; ------------------------------------------------------------------
;;; Radix sort

(defun word-histograms (word perm start end)
  "Digit histograms (a vector of +RADIX-DIGITS+ count vectors) of WORD over
the rows PERM[START, END) (rows START..END-1 themselves when PERM is NIL)."
  (declare (type u64-vector word) (type (or null index-vector) perm)
           (type fixnum start end) (optimize speed))
  (let ((hist (make-array (* +radix-digits+ +radix-buckets+) :element-type 'fixnum
                                                              :initial-element 0)))
    (flet ((count-word (w)
             (declare (type (unsigned-byte 64) w))
             (loop for d of-type fixnum below +radix-digits+
                   do (incf (aref hist (+ (* d +radix-buckets+) (digit-of w d)))))))
      (declare (inline count-word))
      (if perm
          (loop for p of-type fixnum from start below end
                do (count-word (aref word (aref perm p))))
          (loop for i of-type fixnum from start below end
                do (count-word (aref word i)))))
    hist))

(defun trivial-digit-p (hist d n)
  "True when digit D has the same value in all N counted rows."
  (declare (type (simple-array fixnum (*)) hist) (type fixnum d n))
  (loop for b of-type fixnum from (* d +radix-buckets+) below (* (1+ d) +radix-buckets+)
        thereis (= (aref hist b) n)))

(defun radix-pass (keys perm out-keys out-perm hist d m)
  "Stably scatter KEYS/PERM[0, M) into OUT-KEYS/OUT-PERM by digit D, whose
counts are in HIST."
  (declare (type u64-vector keys out-keys) (type index-vector perm out-perm)
           (type (simple-array fixnum (*)) hist) (type radix-digit d) (type fixnum m)
           (optimize speed (safety 0)))
  (let ((offsets (make-array +radix-buckets+ :element-type 'fixnum))
        (base (* d +radix-buckets+))
        (sum 0))
    (declare (type fixnum sum base))
    (dotimes (b +radix-buckets+)
      (setf (aref offsets b) sum)
      (incf sum (aref hist (+ base b))))
    (dotimes (p m)
      (let* ((k (aref keys p))
             (b (digit-of k d))
             (o (aref offsets b)))
        (setf (aref out-keys o) k
              (aref out-perm o) (aref perm p)
              (aref offsets b) (1+ o))))))

(defun radix-sort-range (perm start end words top-digit)
  "Stably sort the rows PERM[START, END) in place by WORDS (most significant
first); digits of the first word above TOP-DIGIT are known to be constant."
  (declare (type index-vector perm) (type fixnum start end) (type radix-digit top-digit))
  (let* ((m (- end start))
         (keys (make-u64-vector m))
         (out-keys (make-u64-vector m))
         (local (subseq perm start end))
         (out-perm (make-index-vector m)))
    (declare (type fixnum m) (type index-vector local out-perm)
             (type u64-vector keys out-keys))
    (loop for (word . more) on (reverse words)
          for first-word = (null more)
          do (let ((word word))
               (declare (type u64-vector word))
               (let ((hist (word-histograms word perm start end))
                     (gathered nil))
                 (loop for d of-type fixnum from 0 below (if first-word (1+ top-digit) +radix-digits+)
                       unless (trivial-digit-p hist d m)
                         do (unless gathered
                              (dotimes (p m)
                                (setf (aref keys p) (aref word (aref local p))))
                              (setf gathered t))
                            (radix-pass keys local out-keys out-perm hist d m)
                            (rotatef keys out-keys)
                            (rotatef local out-perm)))))
    (replace perm local :start1 start)))

(defun top-varying-digit (words n)
  "(values words digit): WORDS without its leading constant words, and the
most significant digit of the first remaining word that varies over the N
rows; NIL when all rows have equal words."
  (loop for rest on words
        do (let ((hist (word-histograms (first rest) nil 0 n)))
             (loop for d from (1- +radix-digits+) downto 0
                   unless (trivial-digit-p hist d n)
                     do (return-from top-varying-digit (values rest d hist))))
        finally (return nil)))

(defun radix-sort-rows (words n threads)
  "Permutation of the rows [0, N) stably sorted by WORDS."
  (multiple-value-bind (words top hist) (top-varying-digit words n)
    (let ((perm (identity-index-vector n)))
      (cond
        ((null words) perm)
        ((or (<= threads 1) (< n (* 2 (morsel-rows))))
         (radix-sort-range perm 0 n words top)
         perm)
        (t
         ;; Partition by the top digit, then sort ranges of whole buckets
         ;; in parallel (each range again by all digits up to the top one).
         (let* ((word (first words))
                (out (make-index-vector n))
                (offsets (make-array +radix-buckets+ :element-type 'fixnum))
                (base (* top +radix-buckets+))
                (sum 0))
           (declare (type u64-vector word) (type fixnum sum)
                    (type (simple-array fixnum (*)) hist))
           (dotimes (b +radix-buckets+)
             (setf (aref offsets b) sum)
             (incf sum (aref hist (+ base b))))
           (dotimes (i n)
             (let ((b (digit-of (aref word i) top)))
               (setf (aref out (aref offsets b)) i)
               (incf (aref offsets b))))
           (let ((ranges '()) (start 0) (acc 0) (target (ceiling n threads)))
             (declare (type fixnum start acc))
             (dotimes (b +radix-buckets+)
               (incf acc (aref hist (+ base b)))
               (when (or (>= (- acc start) target) (= b (1- +radix-buckets+)))
                 (when (> acc start) (push (cons start acc) ranges))
                 (setf start acc)))
             (run-in-threads
              (mapcar (lambda (range)
                        (lambda ()
                          (let ((a (car range)) (b (cdr range)))
                            (when (> (- b a) 1)
                              (radix-sort-range out a b words top)))))
                      ranges)))
           out))))))

(defun resort-inexact-runs (perm words run-words inexact before)
  "Re-sort with the comparison predicate BEFORE every run of PERM whose first
RUN-WORDS words are equal and that holds an INEXACT row."
  (declare (type index-vector perm) (type inexact-flags inexact) (type function before)
           (type fixnum run-words))
  (let ((words (coerce (subseq words 0 run-words) 'simple-vector))
        (n (length perm)))
    (flet ((same-words-p (i j)
             (loop for w across words
                   always (= (aref (the u64-vector w) i) (aref (the u64-vector w) j)))))
      (let ((start 0))
        (declare (type fixnum start))
        (loop while (< start n)
              do (let ((end (1+ start))
                       (any (= 1 (aref inexact (aref perm start)))))
                   (declare (type fixnum end))
                   (loop while (and (< end n) (same-words-p (aref perm start) (aref perm end)))
                         do (when (= 1 (aref inexact (aref perm end))) (setf any t))
                            (incf end))
                   (when (and any (> (- end start) 1))
                     (replace perm (stable-sort (subseq perm start end) before) :start1 start))
                   (setf start end)))))
    perm))

(defun radix-sorted-permutation (batch keys before threads)
  "Row indexes of BATCH in ORDER BY KEYS order (stable), or NIL when a key
cannot be encoded. BEFORE is the comparison predicate for inexact runs."
  (let ((n (batch-count batch)))
    (multiple-value-bind (words run-words inexact) (encode-sort-keys batch keys n threads)
      (when (or words (null keys))
        (let ((perm (radix-sort-rows words n threads)))
          (if run-words
              (resort-inexact-runs perm words run-words inexact before)
              perm))))))
