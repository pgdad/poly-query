;;;; build.lisp — compile the engine with ASDF and save a standalone executable.
;;;;
;;;; Usage: sbcl --non-interactive --no-sysinit --no-userinit --load build.lisp

(require :asdf)

(defparameter *root* (make-pathname :name nil :type nil :defaults *load-truename*))

;; Keep compiled fasls inside build/ instead of the user's cache directory.
(asdf:initialize-output-translations
 `(:output-translations
   :ignore-inherited-configuration
   ((,(namestring *root*) :**/ :*.*.*)
    (,(namestring (merge-pathnames "build/fasl/" *root*)) :**/ :*.*.*))))

(asdf:load-asd (merge-pathnames "polyquery.asd" *root*))

(let ((warnings 0))
  (handler-bind ((warning (lambda (w)
                            (unless (typep w 'sb-kernel:redefinition-warning)
                              (unless (typep w 'style-warning) (incf warnings))
                              (format *error-output* "~&WARNING: ~A~%" w)))))
    (asdf:load-system "polyquery"))
  (when (and (plusp warnings) (uiop:getenv "POLYQUERY_STRICT"))
    (format *error-output* "~&build failed: ~D warnings~%" warnings)
    (uiop:quit 1)))

(sb-ext:save-lisp-and-die (merge-pathnames "build/polyquery" *root*)
                          :executable t
                          :save-runtime-options t
                          :toplevel (lambda () (funcall (intern "MAIN" "POLYQUERY"))))
