;;;; temporal.lisp — DATE and TIMESTAMP text parsing, formatting and calendar math.
;;;;
;;;; DATE values are days since 1970-01-01 (proleptic Gregorian);
;;;; TIMESTAMP values are microseconds since 1970-01-01 00:00:00.

(in-package #:polyquery)

(defconstant +micros-per-second+ 1000000)
(defconstant +micros-per-day+ (* 86400 1000000))

(defun days-from-civil (y m d)
  "Days since 1970-01-01 of the proleptic Gregorian date Y-M-D."
  (let* ((y (if (<= m 2) (1- y) y))
         (era (floor y 400))
         (yoe (- y (* era 400)))
         (doy (+ (floor (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (1- d)))
         (doe (+ (* yoe 365) (floor yoe 4) (- (floor yoe 100)) doy)))
    (+ (* era 146097) doe -719468)))

(defun civil-from-days (z)
  "Inverse of DAYS-FROM-CIVIL. Returns (values year month day)."
  (let* ((z (+ z 719468))
         (era (floor z 146097))
         (doe (- z (* era 146097)))
         (yoe (floor (- doe (floor doe 1460) (- (floor doe 36524)) (floor doe 146096)) 365))
         (y (+ yoe (* era 400)))
         (doy (- doe (+ (* 365 yoe) (floor yoe 4) (- (floor yoe 100)))))
         (mp (floor (+ (* 5 doy) 2) 153))
         (d (1+ (- doy (floor (+ (* 153 mp) 2) 5))))
         (m (if (< mp 10) (+ mp 3) (- mp 9))))
    (values (if (<= m 2) (1+ y) y) m d)))

(defun leap-year-p (y)
  (and (zerop (mod y 4)) (or (not (zerop (mod y 100))) (zerop (mod y 400)))))

(defun days-in-month (y m)
  (case m
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (leap-year-p y) 29 28))))

(defun parse-fixed-digits (s start count)
  "Parse COUNT ASCII digits of S at START, or NIL."
  (when (<= (+ start count) (length s))
    (let ((v 0))
      (loop for i from start below (+ start count)
            for c = (char s i)
            do (if (digit-char-p* c)
                   (setf v (+ (* v 10) (- (char-code c) 48)))
                   (return-from parse-fixed-digits nil)))
      v)))

(defun parse-date-prefix (s)
  "Parse YYYY-MM-DD at the start of S. Returns days or NIL."
  (when (and (>= (length s) 10)
             (char= (char s 4) #\-)
             (char= (char s 7) #\-))
    (let ((y (parse-fixed-digits s 0 4))
          (m (parse-fixed-digits s 5 2))
          (d (parse-fixed-digits s 8 2)))
      (when (and y m d (>= y 1) (<= 1 m 12) (<= 1 d (days-in-month y m)))
        (days-from-civil y m d)))))

(defun parse-date-text (s)
  "Parse ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ as a valid calendar date. Days or NIL."
  (and (= (length s) 10) (parse-date-prefix s)))

(defun parse-timestamp-text (s &key (allow-date-only nil))
  "Parse YYYY-MM-DD[ T]HH:MM:SS[.f{1,6}] into microseconds, or NIL.
With ALLOW-DATE-ONLY, a bare date means midnight."
  (let ((n (length s)))
    (cond ((and allow-date-only (= n 10))
           (let ((days (parse-date-text s)))
             (and days (* days +micros-per-day+))))
          ((and (>= n 19)
                (member (char s 10) '(#\Space #\T))
                (char= (char s 13) #\:)
                (char= (char s 16) #\:))
           (let ((days (parse-date-prefix s))
                 (hh (parse-fixed-digits s 11 2))
                 (mm (parse-fixed-digits s 14 2))
                 (ss (parse-fixed-digits s 17 2))
                 (frac 0))
             (when (> n 19)
               (let ((digits (- n 20)))
                 (unless (and (char= (char s 19) #\.) (<= 1 digits 6))
                   (return-from parse-timestamp-text nil))
                 (let ((f (parse-fixed-digits s 20 digits)))
                   (unless f (return-from parse-timestamp-text nil))
                   (setf frac (* f (pow10 (- 6 digits)))))))
             (when (and days hh mm ss (<= hh 23) (<= mm 59) (<= ss 59))
               (+ (* days +micros-per-day+)
                  (* (+ (* hh 3600) (* mm 60) ss) +micros-per-second+)
                  frac))))
          (t nil))))

(defun format-date (days)
  (multiple-value-bind (y m d) (civil-from-days days)
    (format nil "~4,'0D-~2,'0D-~2,'0D" y m d)))

(defun format-timestamp (micros)
  (multiple-value-bind (days rem) (floor micros +micros-per-day+)
    (multiple-value-bind (secs frac) (floor rem +micros-per-second+)
      (multiple-value-bind (y m d) (civil-from-days days)
        (multiple-value-bind (hh r) (floor secs 3600)
          (multiple-value-bind (mi ss) (floor r 60)
            (if (zerop frac)
                (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D" y m d hh mi ss)
                (format nil "~4,'0D-~2,'0D-~2,'0D ~2,'0D:~2,'0D:~2,'0D.~6,'0D"
                        y m d hh mi ss frac))))))))

(defun date-to-timestamp (days) (* days +micros-per-day+))

(defun timestamp-to-date (micros) (floor micros +micros-per-day+))
