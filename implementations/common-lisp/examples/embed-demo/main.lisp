;;;; main.lisp — pq-embed-demo DATA_DIR CSV_FILE SQL
;;;;
;;;; Creates an engine instance on DATA_DIR, loads CSV_FILE (relative to
;;;; DATA_DIR, header row, inferred schema) as table `t`, runs SQL and prints
;;;; the result as CSV. An engine error prints `error: CODE: MESSAGE` to
;;;; stderr and exits with status 1.

(defpackage #:pq-embed-demo
  (:use #:common-lisp)
  (:local-nicknames (#:pq #:polyquery.api))
  (:export #:main #:run))

(in-package #:pq-embed-demo)

;;; Value text: the engine's canonical text, except FLOAT64 printed like
;;; printf("%.6f") and NULL as an empty field.

(defun float-text (value)
  (let ((micros (round (* (rational value) 1000000))))
    (multiple-value-bind (whole fraction) (floor (abs micros) 1000000)
      (format nil "~:[~;-~]~D.~6,'0D" (minusp micros) whole fraction))))

(defun value-text (value column)
  (cond ((pq:null-value-p value) nil)
        ((string= (pq:column-type column) "FLOAT64") (float-text value))
        (t (pq:value-text value column))))

(defun csv-field (text)
  "TEXT (NIL for NULL) as a CSV field, quoted where needed."
  (if (and text
           (or (zerop (length text))
               (find-if (lambda (c) (find c (format nil ",\"~C~C" #\Return #\Newline))) text)
               (char= (char text 0) #\Space)
               (char= (char text (1- (length text))) #\Space)))
      (with-output-to-string (s)
        (write-char #\" s)
        (loop for c across text
              do (when (char= c #\") (write-char #\" s))
                 (write-char c s))
        (write-char #\" s))
      (or text "")))

(defun write-csv-record (fields out)
  (format out "~{~A~^,~}~%" (mapcar #'csv-field fields)))

(defun print-result (result out)
  (write-csv-record (pq:result-column-names result) out)
  (pq:do-result-rows (row result)
    (write-csv-record (loop for column in (pq:result-columns result)
                            for value across row
                            collect (value-text value column))
                      out)))

(defun run (data-dir csv-file sql out)
  "The demo itself; returns the exit status."
  (handler-case
      (pq:with-database (db :data-dir data-dir)
        (pq:load-csv db "t" :path csv-file)
        (print-result (pq:query db sql) out)
        0)
    (pq:engine-error (e)
      (format *error-output* "error: ~A: ~A~%" (pq:engine-error-code e) (pq:engine-error-message e))
      1)))

(defun main ()
  (let ((args (rest sb-ext:*posix-argv*))
        (out (sb-sys:make-fd-stream 1 :output t :buffering :full :external-format :utf-8)))
    (sb-ext:exit
     :abort t
     :code (if (= (length args) 3)
               (prog1 (apply #'run (append args (list out)))
                 (finish-output out)
                 (finish-output *error-output*))
               (progn
                 (format *error-output* "usage: pq-embed-demo DATA_DIR CSV_FILE SQL~%")
                 (finish-output *error-output*)
                 2)))))
