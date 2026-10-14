;;;; conditions.lisp — application errors and their exit statuses (pqledger.md §10).

(in-package #:pqledger)

(define-condition pqledger-error (error)
  ((exit-status :initarg :exit-status :reader exit-status)
   (message :initarg :message :reader error-message))
  (:report (lambda (c s) (write-string (error-message c) s)))
  (:documentation "A failure reported as `pqledger: error: MESSAGE` with EXIT-STATUS."))

(defmacro define-failure (name exit-status documentation)
  `(defun ,name (format-control &rest args)
     ,documentation
     (error 'pqledger-error :exit-status ,exit-status
                            :message (apply #'format nil format-control args))))

(define-failure usage-error 1 "Signal a command line usage error.")
(define-failure config-error 2 "Signal an error in the configuration, rules or budget file.")
(define-failure import-error 4 "Signal invalid import data.")
(define-failure query-error 5 "Signal an engine error of the `query` command.")
(define-failure ledger-error 6 "Signal a ledger state error.")
(define-failure fatal-error 7 "Signal any other error (I/O, unexpected engine errors).")
