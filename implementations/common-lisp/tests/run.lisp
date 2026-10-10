;;;; run.lisp — load the engine and run its unit tests (used by `make test`).

(require :asdf)
(require :sb-rt)

(defparameter *root* (merge-pathnames "../" (make-pathname :name nil :type nil
                                                           :defaults *load-truename*)))

(asdf:initialize-output-translations
 `(:output-translations
   :ignore-inherited-configuration
   ((,(namestring (truename *root*)) :**/ :*.*.*)
    (,(namestring (merge-pathnames "build/fasl/" (truename *root*))) :**/ :*.*.*))))

(asdf:load-asd (merge-pathnames "polyquery.asd" (truename *root*)))
(asdf:load-system "polyquery/tests")

(uiop:quit (if (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
                 (uiop:symbol-call '#:polyquery-tests '#:run-all-tests))
               0 1))
