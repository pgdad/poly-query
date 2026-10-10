;;;; package.lisp — package definition for the PolyQuery engine.

(defpackage #:polyquery
  (:use #:common-lisp)
  (:export
   ;; entry points
   #:main
   #:*engine-version*
   ;; errors
   #:pq-error #:pq-error-code #:pq-error-message #:pq-error-details #:signal-pq-error
   ;; json
   #:parse-json #:write-json #:json-to-string #:jobj #:json-object #:json-object-pairs
   #:json-get #:make-jnum #:jnum #:jnum-text
   ;; types & values
   #:parse-type-name #:type-name-string #:format-decimal #:parse-date-text
   #:parse-timestamp-text #:format-date #:format-timestamp #:format-float
   #:days-from-civil #:civil-from-days
   ;; catalog / engine
   #:make-engine-config #:make-session #:handle-request #:execute-sql
   #:tokenize #:parse-sql))
