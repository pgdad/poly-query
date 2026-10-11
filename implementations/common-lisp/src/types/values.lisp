;;;; values.lisp — value conversion (text parsing, CAST) and canonical serialization.

(in-package #:polyquery)

;;; ------------------------------------------------------------------
;;; Text -> value (shared by ingestion and CAST from STRING)
;;;
;;; TEXT-TO-VALUE returns (values value status), STATUS being :OK, :INVALID
;;; (syntax/domain error) or :OVERFLOW (syntactically valid, out of range).
;;; The caller decides which error code each status maps to.

(defun text-to-boolean (s)
  (cond ((string-equal s "true") (values t :ok))
        ((string-equal s "false") (values nil :ok))
        (t (values nil :invalid))))

(defun text-to-int64 (s)
  (let ((v (parse-int-text s)))
    (cond ((null v) (values nil :invalid))
          ((int64-p v) (values v :ok))
          (t (values nil :overflow)))))

(defun text-to-float64 (s)
  (multiple-value-bind (d status) (parse-float-text s)
    (if (eq status :ok)
        (values d :ok)
        (values nil (if (eq status :overflow) :overflow :invalid)))))

(defun text-to-decimal (s precision scale &key (rounding nil))
  "Parse decimal text for DECIMAL(PRECISION,SCALE). Without ROUNDING, more
fractional digits than SCALE is :INVALID (ingestion is exact)."
  (multiple-value-bind (unscaled frac) (parse-decimal-text s)
    (cond ((null unscaled) (values nil :invalid))
          ((and (> frac scale) (not rounding)) (values nil :invalid))
          (t (let ((v (rescale-decimal unscaled frac scale)))
               (if (fits-precision-p v precision)
                   (values v :ok)
                   (values nil :overflow)))))))

(defun text-to-value (s type &key (rounding nil) (date-as-timestamp t))
  "Convert already-trimmed text S to a value of TYPE. DATE-AS-TIMESTAMP accepts
a bare date for TIMESTAMP (ingestion does; CAST requires timestamp syntax)."
  (ecase (type-kind type)
    (:boolean (text-to-boolean s))
    (:int64 (text-to-int64 s))
    (:float64 (text-to-float64 s))
    (:decimal (text-to-decimal s (decimal-precision type) (decimal-scale type)
                               :rounding rounding))
    (:string (values s :ok))
    (:date (let ((d (parse-date-text s)))
             (if d (values d :ok) (values nil :invalid))))
    (:timestamp (let ((ts (parse-timestamp-text s :allow-date-only date-as-timestamp)))
                  (if ts (values ts :ok) (values nil :invalid))))))

;;; ------------------------------------------------------------------
;;; Value -> text

(defun value-to-text (value type)
  "Text form of a non-NULL value (CAST to STRING, CONCAT)."
  (ecase (type-kind type)
    (:boolean (if value "true" "false"))
    (:int64 (format nil "~D" value))
    (:float64 (format-float value))
    (:decimal (format-decimal value (decimal-scale type)))
    (:string value)
    (:date (format-date value))
    (:timestamp (format-timestamp value))))

;;; ------------------------------------------------------------------
;;; CAST

(defun cast-supported-p (from to)
  "Whether CAST(x AS TO) is valid for an operand of type FROM (types.md §8)."
  (let ((f (type-kind from)) (k (type-kind to)))
    (or (eq f :null)
        (eq f k)
        (eq f :string)
        (eq k :string)
        (ecase f
          (:boolean (eq k :int64))
          (:int64 (member k '(:boolean :decimal :float64)))
          (:decimal (member k '(:int64 :float64)))
          (:float64 (member k '(:int64 :decimal)))
          ((:date :timestamp) (member k '(:date :timestamp)))))))

(defun float-to-int64 (d)
  (let ((v (truncate d)))
    (if (int64-p v) v (overflow-error "value out of INT64 range"))))

(defun check-decimal-fits (unscaled precision)
  (if (fits-precision-p unscaled precision)
      unscaled
      (overflow-error "value does not fit DECIMAL(~D)" precision)))

(defun make-cast-function (from to)
  "Return a function converting a non-NULL value of type FROM to type TO."
  (let ((f (type-kind from)) (k (type-kind to)))
    (macrolet ((fn (&body body) `(lambda (v) ,@body)))
      (cond
        ((type-equal from to) #'identity)
        ((eq f :null) (constantly +null+))
        ((eq k :string) (fn (value-to-text v from)))
        ((eq f :string)
         (fn (let ((s (trim-whitespace v)))
               (multiple-value-bind (value status) (text-to-value s to :rounding t :date-as-timestamp nil)
                 (ecase status
                   (:ok value)
                   (:overflow (overflow-error "value ~S out of range for ~A" s (type-name-string to)))
                   (:invalid (conversion-error "cannot convert ~S to ~A" s (type-name-string to))))))))
        (t
         (ecase f
           (:boolean (ecase k (:int64 (fn (if v 1 0)))))
           (:int64
            (ecase k
              (:boolean (fn (/= v 0)))
              (:float64 (fn (coerce v 'double-float)))
              (:decimal (let ((p (decimal-precision to)) (s (decimal-scale to)))
                          (fn (check-decimal-fits (* v (pow10 s)) p))))))
           (:decimal
            (let ((s (decimal-scale from)))
              (ecase k
                (:int64 (fn (truncate v (pow10 s))))
                (:float64 (fn (rational-to-double (/ v (pow10 s)))))
                (:decimal (let ((p2 (decimal-precision to)) (s2 (decimal-scale to)))
                            (fn (check-decimal-fits (rescale-decimal v s s2) p2)))))))
           (:float64
            (ecase k
              (:int64 #'float-to-int64)
              (:decimal (let ((p (decimal-precision to)) (s (decimal-scale to)))
                          (fn (check-decimal-fits (rational-to-decimal (rational v) s) p))))))
           (:date (ecase k (:timestamp #'date-to-timestamp)))
           (:timestamp (ecase k (:date #'timestamp-to-date)))))))))

;;; ------------------------------------------------------------------
;;; Serialization (types.md §9)

(defun render-decimal (unscaled scale cb)
  "Append the canonical DECIMAL text of UNSCALED with SCALE (as FORMAT-DECIMAL)."
  (if (zerop scale)
      (cb-integer cb unscaled)
      (multiple-value-bind (int frac) (truncate (abs unscaled) (pow10 scale))
        (when (minusp unscaled) (cb-char cb #\-))
        (cb-integer cb int)
        (cb-char cb #\.)
        (cb-integer cb frac scale))))

(defun render-value (value type cb)
  "Append the canonical JSON representation of VALUE of TYPE to the CHARBUF CB."
  (if (null-value-p value)
      (cb-string cb "null")
      (ecase (type-kind type)
        (:boolean (cb-string cb (if value "true" "false")))
        (:int64 (cb-integer cb value))
        (:float64 (cb-string cb (format-float value)))
        ;; DECIMAL, DATE and TIMESTAMP texts never need JSON escaping.
        (:decimal (cb-char cb #\") (render-decimal value (decimal-scale type) cb) (cb-char cb #\"))
        (:string (cb-json-string cb value))
        (:date (cb-char cb #\") (render-date value cb) (cb-char cb #\"))
        (:timestamp (cb-char cb #\") (render-timestamp value cb) (cb-char cb #\"))
        (:null (cb-string cb "null")))))

(defun write-value (value type stream)
  "Write VALUE of TYPE as its canonical JSON representation."
  (let ((cb (make-charbuf 64)))
    (render-value value type cb)
    (cb-flush cb stream)))

(defun value-to-json (value type)
  "Convert VALUE of TYPE into a JSON value suitable for WRITE-JSON."
  (if (null-value-p value)
      :null
      (ecase (type-kind type)
        (:boolean (if value :true :false))
        (:int64 value)
        (:float64 value)
        (:decimal (format-decimal value (decimal-scale type)))
        (:string value)
        (:date (format-date value))
        (:timestamp (format-timestamp value))
        (:null :null))))
