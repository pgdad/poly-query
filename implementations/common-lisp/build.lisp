;;;; build.lisp — compile a system with ASDF and save it as a standalone executable.
;;;;
;;;; Usage: sbcl --non-interactive --no-sysinit --no-userinit --load build.lisp
;;;;
;;;; By default this builds the engine (build/polyquery). The environment
;;;; variables BUILD_SYSTEM, BUILD_TOPLEVEL and BUILD_OUTPUT select another
;;;; ASDF system, its entry point and the executable, e.g. pqledger with
;;;; pqledger:main and build/pqledger (see the Makefile).

(require :asdf)

(defparameter *root* (make-pathname :name nil :type nil :defaults *load-truename*))

(defun build-setting (name default)
  (let ((value (uiop:getenv name)))
    (if (and value (plusp (length value))) value default)))

;; Keep compiled fasls inside build/ instead of the user's cache directory.
(asdf:initialize-output-translations
 `(:output-translations
   :ignore-inherited-configuration
   ((,(namestring *root*) :**/ :*.*.*)
    (,(namestring (merge-pathnames "build/fasl/" *root*)) :**/ :*.*.*))))

;; The systems of this directory: the engine and its embedding API
;; (polyquery.asd), the application (app/) and the embedding example.
(asdf:initialize-source-registry
 `(:source-registry
   :ignore-inherited-configuration
   (:directory ,*root*)
   (:directory ,(merge-pathnames "app/" *root*))
   (:directory ,(merge-pathnames "examples/embed-demo/" *root*))))

(defparameter *system* (build-setting "BUILD_SYSTEM" "polyquery"))
(defparameter *toplevel* (build-setting "BUILD_TOPLEVEL" "polyquery:main"))
(defparameter *output* (merge-pathnames (build-setting "BUILD_OUTPUT" "build/polyquery") *root*))

(let ((warnings 0))
  (handler-bind ((warning (lambda (w)
                            (unless (typep w 'sb-kernel:redefinition-warning)
                              (unless (typep w 'style-warning) (incf warnings))
                              (format *error-output* "~&WARNING: ~A~%" w)))))
    (asdf:load-system *system*))
  (when (and (plusp warnings) (uiop:getenv "POLYQUERY_STRICT"))
    (format *error-output* "~&build failed: ~D warnings~%" warnings)
    (uiop:quit 1)))

(let ((entry (let ((*package* (find-package "KEYWORD")))
               (read-from-string *toplevel*))))
  (unless (fboundp entry)
    (format *error-output* "~&build failed: ~A is not a function~%" *toplevel*)
    (uiop:quit 1))
  (sb-ext:save-lisp-and-die *output*
                            :executable t
                            :save-runtime-options t
                            :toplevel (lambda () (funcall entry))))
