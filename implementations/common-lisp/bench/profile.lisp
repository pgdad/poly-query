;;;; profile.lisp — statistical profile of one query (development aid).
;;;;
;;;; sbcl --dynamic-space-size 8192 --non-interactive --load bench/profile.lisp \
;;;;      DATA-DIR TABLE=FILE[,TABLE=FILE...] MODE THREADS REPEAT "SQL"
;;;; e.g. bench/profile.lisp /tmp/pqdata/1m/ tx=transactions vectorized 1 5 "SELECT ..."

(require :asdf)
(require :sb-sprof)

(defparameter *root* (merge-pathnames "../" (make-pathname :name nil :type nil
                                                           :defaults *load-truename*)))
(asdf:initialize-output-translations
 `(:output-translations
   :ignore-inherited-configuration
   ((,(namestring (truename *root*)) :**/ :*.*.*)
    (,(namestring (merge-pathnames "build/fasl/" (truename *root*))) :**/ :*.*.*))))
(asdf:load-asd (merge-pathnames "polyquery.asd" (truename *root*)))
(asdf:load-system "polyquery")

(in-package #:polyquery)

(destructuring-bind (data-dir tables mode threads repeat sql)
    (last sb-ext:*posix-argv* 6)
  (let ((session (make-session (make-engine-config :data-dir data-dir)))
        (options (make-exec-options :mode (intern (string-upcase mode) :keyword)
                                    :threads (parse-integer threads))))
    (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
      (dolist (spec (split-string tables #\,))
        (destructuring-bind (name file) (split-string spec #\=)
          (let ((schema (with-open-file (in (format nil "~A~A.schema.json" data-dir file))
                          (parse-json (read-line in)))))
            (print (handle-request session (jobj "op" "load" "table" name "format" "csv"
                                                 "path" (format nil "~A.csv" file)
                                                 "schema" schema))))))
      (flet ((run () (query-result-row-count (execute-sql session sql :options options))))
        (format t "~&rows: ~D~%" (run))
        (let ((start (get-internal-real-time)))
          (dotimes (i (parse-integer repeat)) (run))
          (format t "~&avg ms: ~,1F~%" (/ (- (get-internal-real-time) start)
                                          (/ internal-time-units-per-second 1000)
                                          (parse-integer repeat))))
        (sb-sprof:with-profiling (:max-samples 100000 :sample-interval 0.0005 :report :flat
                                  :mode :cpu :threads :all)
          (dotimes (i (parse-integer repeat)) (run)))))))
