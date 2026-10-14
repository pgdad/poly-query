;;;; run.lisp — load pqledger and run its unit tests (used by `make test`).

(require :asdf)
(require :sb-rt)

(defparameter *root* (truename (merge-pathnames "../../" (make-pathname :name nil :type nil
                                                                         :defaults *load-truename*))))

(asdf:initialize-output-translations
 `(:output-translations
   :ignore-inherited-configuration
   ((,(namestring *root*) :**/ :*.*.*)
    (,(namestring (merge-pathnames "build/fasl/" *root*)) :**/ :*.*.*))))

(asdf:initialize-source-registry
 `(:source-registry
   :ignore-inherited-configuration
   (:directory ,*root*)
   (:directory ,(merge-pathnames "app/" *root*))))

(asdf:load-system "pqledger/tests")

(uiop:quit (if (uiop:symbol-call '#:pqledger-tests '#:run-all-tests) 0 1))
