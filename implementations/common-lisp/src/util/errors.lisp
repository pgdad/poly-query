;;;; errors.lisp — the engine-wide error condition carrying a stable error code.

(in-package #:polyquery)

(define-condition pq-error (error)
  ((code :initarg :code :reader pq-error-code
         :documentation "Stable error code string from spec/errors/error-codes.json.")
   (message :initarg :message :reader pq-error-message)
   (details :initarg :details :initform nil :reader pq-error-details
            :documentation "Alist of (key . json-value) or NIL."))
  (:report (lambda (c s)
             (format s "~A: ~A" (pq-error-code c) (pq-error-message c)))))

(defun signal-pq-error (code format-control &rest args)
  "Signal a PQ-ERROR with CODE and a message built from FORMAT-CONTROL and ARGS."
  (error 'pq-error :code code :message (apply #'format nil format-control args)))

(defun signal-pq-error-with-details (code details format-control &rest args)
  (error 'pq-error :code code :details details
                   :message (apply #'format nil format-control args)))

(defmacro define-error-shorthand (name code)
  `(defun ,name (format-control &rest args)
     (apply #'signal-pq-error ,code format-control args)))

(define-error-shorthand semantic-error "SEMANTIC_ERROR")
(define-error-shorthand type-error* "TYPE_ERROR")
(define-error-shorthand overflow-error "NUMERIC_OVERFLOW")
(define-error-shorthand division-by-zero-error "DIVISION_BY_ZERO")
(define-error-shorthand conversion-error "CONVERSION_ERROR")
(define-error-shorthand invalid-argument-error "INVALID_ARGUMENT")
(define-error-shorthand invalid-request-error "INVALID_REQUEST")
(define-error-shorthand ingest-error "INGEST_ERROR")
(define-error-shorthand unsupported-error "UNSUPPORTED")
(define-error-shorthand resource-limit-error "RESOURCE_LIMIT")
