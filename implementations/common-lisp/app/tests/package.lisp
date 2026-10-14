;;;; package.lisp — unit tests of pqledger (sb-rt, like the engine's tests).

(defpackage #:pqledger-tests
  (:use #:common-lisp #:sb-rt)
  (:local-nicknames (#:pq #:polyquery.api))
  (:export #:run-all-tests))

(in-package #:pqledger-tests)

(rem-all-tests)

(defun exit-status-of (thunk)
  "Run THUNK; the exit status of the PQLEDGER-ERROR it signals, or :OK."
  (handler-case (progn (funcall thunk) :ok)
    (pqledger::pqledger-error (e) (pqledger::exit-status e))))

(defmacro status-of (&body body)
  `(exit-status-of (lambda () ,@body)))

(defun temporary-directory ()
  "A fresh, empty directory (native path with a trailing slash)."
  (let ((base (format nil "/tmp/pqledger-test-~D-~D/" (sb-posix:getpid) (random 1000000000))))
    (ensure-directories-exist base)
    base))

(defun write-file (path text)
  (with-open-file (out path :direction :output :if-exists :supersede :external-format :utf-8)
    (write-string text out))
  path)

(defun run-all-tests ()
  "Run every registered test; returns true when all pass."
  (do-tests))
