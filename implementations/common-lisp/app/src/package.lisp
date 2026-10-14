;;;; package.lisp — the pqledger application package.
;;;;
;;;; pqledger uses the engine only through its public embedding API
;;;; (package POLYQUERY.API, nicknamed PQ here).

(defpackage #:pqledger
  (:use #:common-lisp)
  (:local-nicknames (#:pq #:polyquery.api))
  (:export #:main #:run #:*version*))

(in-package #:pqledger)

(defparameter *version* "1.0.0"
  "The application version (pqledger application spec 1.0.0).")
