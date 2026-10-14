;;;; main.lisp — the process entry point: streams, error reporting, exit status
;;;; (pqledger.md §10).

(in-package #:pqledger)

(defun run (args out)
  "Run pqledger with the command line ARGS, writing normal output to the
stream OUT. Returns the exit status; failures are reported on
*ERROR-OUTPUT* and produce no output on OUT."
  (flet ((fail (status format-control &rest format-args)
           (format *error-output* "pqledger: error: ~?~%" format-control format-args)
           (return-from run status)))
    (let ((buffer (make-string-output-stream))
          (status 0))
      (handler-case
          (setf status (execute (parse-command-line args) buffer))
        (pqledger-error (e)
          (when (= (exit-status e) 1)
            (fail 1 "~A~%Try `pqledger help` for usage." (error-message e)))
          (fail (exit-status e) "~A" (error-message e)))
        (pq:engine-error (e)
          (fail 7 "~A: ~A" (pq:engine-error-code e) (pq:engine-error-message e)))
        (sb-sys:interactive-interrupt ()
          (fail 7 "interrupted"))
        (storage-condition ()
          (fail 7 "out of memory"))
        (error (e)
          (fail 7 "~A" e)))
      (write-string (get-output-stream-string buffer) out)
      status)))

(defun main ()
  "Entry point of the pqledger executable."
  (let ((out (sb-sys:make-fd-stream 1 :output t :buffering :full :external-format :utf-8))
        (*error-output* (sb-sys:make-fd-stream 2 :output t :buffering :line :external-format :utf-8))
        (status 7))
    ;; Fewer, larger young-generation collections suit the batch work here.
    (setf (sb-ext:bytes-consed-between-gcs) (* 256 1024 1024))
    (handler-case
        (progn
          (setf status (run (rest sb-ext:*posix-argv*) out))
          (finish-output out))
      (sb-int:broken-pipe () (setf status 0))
      (stream-error () (setf status 7)))
    (ignore-errors (finish-output *error-output*))
    (sb-ext:exit :code status :abort t)))
