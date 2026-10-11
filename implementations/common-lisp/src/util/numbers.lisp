;;;; numbers.lisp — exact numeric text parsing and canonical number formatting.
;;;;
;;;; Everything here is pure and independent of SQL types: INT64 range checks,
;;;; decimal text <-> scaled integers, correctly rounded float parsing and
;;;; shortest round-trip float printing.

(in-package #:polyquery)

(defconstant +int64-min+ (- (expt 2 63)))
(defconstant +int64-max+ (1- (expt 2 63)))
(defconstant +max-decimal-precision+ 38
  "Largest DECIMAL precision (CR-2: decimals of precision 19-38 are *wide*).")
(defconstant +narrow-decimal-precision+ 18
  "Largest precision of a *narrow* DECIMAL, whose unscaled values fit INT64,
and the result precision of operations on narrow operands.")

(declaim (inline int64-p))
(defun int64-p (n)
  (and (integerp n) (<= +int64-min+ n +int64-max+)))

(defun check-int64 (n)
  "Return N if it fits INT64, else signal NUMERIC_OVERFLOW."
  (if (<= +int64-min+ n +int64-max+)
      n
      (overflow-error "INT64 overflow")))

(defparameter *powers-of-ten*
  (let ((v (make-array 40)))
    (dotimes (i 40 v) (setf (aref v i) (expt 10 i)))))

(declaim (inline pow10))
(defun pow10 (n)
  (if (< n 40) (svref *powers-of-ten* n) (expt 10 n)))

(defun digit-count (n)
  "Number of decimal digits of |N| (0 has one digit)."
  (let ((n (abs n)))
    (if (zerop n)
        1
        (loop for d from 1
              for p = 10 then (* p 10)
              when (< n p) return d))))

(defun fits-precision-p (unscaled precision)
  (< (abs unscaled) (pow10 precision)))

(defun round-half-away (numerator denominator)
  "Round the rational NUMERATOR/DENOMINATOR (DENOMINATOR > 0) to an integer,
ties away from zero."
  (multiple-value-bind (q r) (truncate numerator denominator)
    (if (>= (* 2 (abs r)) denominator)
        (+ q (if (minusp numerator) -1 1))
        q)))

(defun rescale-decimal (unscaled from-scale to-scale)
  "Change the scale of an unscaled decimal value, rounding half away from zero
when reducing the scale."
  (cond ((= from-scale to-scale) unscaled)
        ((< from-scale to-scale) (* unscaled (pow10 (- to-scale from-scale))))
        (t (round-half-away unscaled (pow10 (- from-scale to-scale))))))

(defun rational-to-decimal (r scale)
  "Round the exact rational R to an unscaled integer at SCALE (half away from zero)."
  (let ((x (* r (pow10 scale))))
    (round-half-away (numerator x) (denominator x))))

;;; ------------------------------------------------------------------
;;; Character helpers

(declaim (inline digit-char-p* ascii-space-p))
(defun digit-char-p* (c)
  (char<= #\0 c #\9))

(defun ascii-space-p (c)
  (or (char= c #\Space) (char= c #\Tab)))

(defun trim-spaces-tabs (s)
  "Trim ASCII spaces and tabs (the CSV trimming rule)."
  (string-trim '(#\Space #\Tab) s))

(defun trim-whitespace (s)
  "Trim ASCII whitespace (used by CAST from STRING)."
  (string-trim '(#\Space #\Tab #\Newline #\Return #\Page) s))

(defun ascii-downcase (s)
  "ASCII-only case folding (identifiers, table and column names)."
  (let ((r (copy-seq s)))
    (dotimes (i (length r) r)
      (let ((c (char r i)))
        (when (char<= #\A c #\Z)
          (setf (char r i) (code-char (+ (char-code c) 32))))))))

(defun ascii-upcase (s)
  (let ((r (copy-seq s)))
    (dotimes (i (length r) r)
      (let ((c (char r i)))
        (when (char<= #\a c #\z)
          (setf (char r i) (code-char (- (char-code c) 32))))))))

(defun ascii-string-equal (a b)
  (and (= (length a) (length b))
       (string= (ascii-downcase a) (ascii-downcase b))))

;;; ------------------------------------------------------------------
;;; Integer text

(defun parse-int-text (s)
  "Parse ^[+-]?[0-9]+$ into an integer (unbounded), or return NIL when the
syntax does not match."
  (let ((n (length s)) (i 0) (neg nil))
    (when (zerop n) (return-from parse-int-text nil))
    (case (char s 0)
      (#\+ (incf i))
      (#\- (incf i) (setf neg t)))
    (when (>= i n) (return-from parse-int-text nil))
    (let ((v 0))
      (loop for j from i below n
            for c = (char s j)
            do (if (digit-char-p* c)
                   (setf v (+ (* v 10) (- (char-code c) 48)))
                   (return-from parse-int-text nil)))
      (if neg (- v) v))))

;;; ------------------------------------------------------------------
;;; Decimal text: ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)$

(defun parse-decimal-text (s)
  "Parse plain decimal text. Returns (values unscaled-integer fraction-digits)
or NIL if the syntax does not match. No exponent allowed."
  (let ((n (length s)) (i 0) (neg nil) (v 0) (int-digits 0) (frac-digits 0))
    (when (zerop n) (return-from parse-decimal-text nil))
    (case (char s 0)
      (#\+ (incf i))
      (#\- (incf i) (setf neg t)))
    (loop while (and (< i n) (digit-char-p* (char s i)))
          do (setf v (+ (* v 10) (- (char-code (char s i)) 48)))
             (incf int-digits) (incf i))
    (when (and (< i n) (char= (char s i) #\.))
      (incf i)
      (loop while (and (< i n) (digit-char-p* (char s i)))
            do (setf v (+ (* v 10) (- (char-code (char s i)) 48)))
               (incf frac-digits) (incf i)))
    (if (and (= i n) (plusp (+ int-digits frac-digits)))
        (values (if neg (- v) v) frac-digits)
        nil)))

(defun format-decimal (unscaled scale)
  "Canonical DECIMAL text: exactly SCALE fractional digits, leading '-' for
negative values, at least one integer digit."
  (let* ((neg (minusp unscaled))
         (digits (format nil "~D" (abs unscaled))))
    (when (< (length digits) (1+ scale))
      (setf digits (concatenate 'string
                                (make-string (- (1+ scale) (length digits))
                                             :initial-element #\0)
                                digits)))
    (let ((split (- (length digits) scale)))
      (concatenate 'string
                   (if neg "-" "")
                   (subseq digits 0 split)
                   (if (plusp scale) "." "")
                   (subseq digits split)))))

;;; ------------------------------------------------------------------
;;; Floats

(defconstant +double-overflow-threshold+
  ;; Smallest rational that rounds to +infinity: max-double + half an ulp.
  (- (expt 2 1024) (expt 2 970)))

(defparameter *exact-double-powers*
  (let ((v (make-array 23 :element-type 'double-float)))
    (dotimes (i 23 v) (setf (aref v i) (coerce (expt 10 i) 'double-float)))))

(defun rational-to-double (r)
  "Correctly rounded conversion of an exact rational to a double. Returns
(values double ok-p) where OK-P is NIL on overflow."
  (if (>= (abs r) +double-overflow-threshold+)
      (values 0d0 nil)
      (values (coerce r 'double-float) t)))

(defun parse-float-text (s &key (allow-sign t))
  "Parse ^[+-]?([0-9]+\\.?[0-9]*|\\.[0-9]+)([eE][+-]?[0-9]+)?$ into a double.
Returns (values double status) with status :ok, :syntax or :overflow."
  (let ((n (length s)) (i 0) (neg nil) (mant 0) (ndigits 0) (frac 0) (exp 0))
    (when (zerop n) (return-from parse-float-text (values 0d0 :syntax)))
    (when allow-sign
      (case (char s 0)
        (#\+ (incf i))
        (#\- (incf i) (setf neg t))))
    (let ((int-digits 0) (frac-digits 0))
      (loop while (and (< i n) (digit-char-p* (char s i)))
            do (setf mant (+ (* mant 10) (- (char-code (char s i)) 48)))
               (incf int-digits) (incf i))
      (when (and (< i n) (char= (char s i) #\.))
        (incf i)
        (loop while (and (< i n) (digit-char-p* (char s i)))
              do (setf mant (+ (* mant 10) (- (char-code (char s i)) 48)))
                 (incf frac-digits) (incf i)))
      (when (zerop (+ int-digits frac-digits))
        (return-from parse-float-text (values 0d0 :syntax)))
      (setf ndigits (+ int-digits frac-digits) frac frac-digits))
    (when (and (< i n) (char-equal (char s i) #\e))
      (incf i)
      (let ((eneg nil) (edigits 0))
        (when (< i n)
          (case (char s i)
            (#\+ (incf i))
            (#\- (incf i) (setf eneg t))))
        (loop while (and (< i n) (digit-char-p* (char s i)))
              do (when (< exp 100000000)
                   (setf exp (+ (* exp 10) (- (char-code (char s i)) 48))))
                 (incf edigits) (incf i))
        (when (zerop edigits) (return-from parse-float-text (values 0d0 :syntax)))
        (when eneg (setf exp (- exp)))))
    (unless (= i n) (return-from parse-float-text (values 0d0 :syntax)))
    (let ((e10 (- exp frac)))
      (flet ((done (d) (values (if neg (- d) d) :ok)))
        (cond ((zerop mant) (done 0d0))
              ((and (< mant (expt 2 53)) (<= -22 e10 22))
               (done (if (minusp e10)
                         (/ (coerce mant 'double-float) (aref *exact-double-powers* (- e10)))
                         (* (coerce mant 'double-float) (aref *exact-double-powers* e10)))))
              ((> (+ e10 ndigits) 330) (values 0d0 :overflow))
              ((< (+ e10 ndigits) -360) (done 0d0))
              (t
               (multiple-value-bind (d ok)
                   (rational-to-double (if (minusp e10)
                                           (/ mant (pow10 (- e10)))
                                           (* mant (pow10 e10))))
                 (if ok (done d) (values 0d0 :overflow)))))))))

(declaim (inline finite-double-p))
(defun finite-double-p (d)
  (and (= d d) (< (abs d) sb-ext:double-float-positive-infinity)))

(defun check-finite (d)
  (if (finite-double-p d)
      d
      (overflow-error "FLOAT64 result is not finite")))

(defun format-float (d)
  "Shortest text that reads back as the identical double. -0.0 prints as 0.0."
  (declare (type double-float d))
  (when (zerop d) (return-from format-float "0.0"))
  (multiple-value-bind (k digits) (sb-impl::flonum-to-digits (abs d))
    ;; value = 0.DIGITS * 10^K
    (let ((n (length digits))
          (sign (if (minusp d) "-" "")))
      (cond ((and (<= k 0) (> k -6))
             (concatenate 'string sign "0." (make-string (- k) :initial-element #\0) digits))
            ((and (> k 0) (<= k 21))
             (if (>= k n)
                 (concatenate 'string sign digits (make-string (- k n) :initial-element #\0) ".0")
                 (concatenate 'string sign (subseq digits 0 k) "." (subseq digits k))))
            (t
             (concatenate 'string sign (subseq digits 0 1)
                          (if (> n 1) "." "")
                          (subseq digits 1)
                          "e" (princ-to-string (1- k))))))))
