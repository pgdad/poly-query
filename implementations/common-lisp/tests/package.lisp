;;;; package.lisp — unit test package (tests use SBCL's bundled sb-rt).

(defpackage #:polyquery-tests
  (:use #:common-lisp #:sb-rt)
  (:import-from #:polyquery
                #:parse-json #:json-to-string #:jobj #:make-jnum
                #:format-float #:format-decimal #:parse-float-text #:parse-decimal-text
                #:parse-date-text #:parse-timestamp-text #:format-date #:format-timestamp
                #:days-from-civil #:civil-from-days #:parse-type-string #:type-name-string
                #:tokenize #:parse-sql #:execute-sql #:make-session #:make-engine-config
                #:handle-request #:pq-error #:pq-error-code)
  (:export #:run-all-tests))

(in-package #:polyquery-tests)

(defun error-code-of (thunk)
  "Run THUNK and return the PQ-ERROR code it signals, or :NO-ERROR."
  (handler-case (progn (funcall thunk) :no-error)
    (pq-error (e) (pq-error-code e))))

(defmacro code-of (&body body)
  `(error-code-of (lambda () ,@body)))

(defun run-all-tests ()
  "Run every registered test; returns true when all pass."
  (do-tests))
