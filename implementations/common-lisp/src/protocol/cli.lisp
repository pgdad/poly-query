;;;; cli.lisp — command line entry point: version, capabilities, session, exec, serve.

(in-package #:polyquery)

(define-condition usage-error (error)
  ((message :initarg :message :reader usage-error-message))
  (:report (lambda (c s) (write-string (usage-error-message c) s))))

(defun usage-error (format-control &rest args)
  (error 'usage-error :message (apply #'format nil format-control args)))

(defparameter *option-specs*
  ;; option -> (kind . keyword); kind is :flag, :integer or :string
  '(("--data-dir" :string . :data-dir)
    ("--enable-test-functions" :flag . :test-functions)
    ("--max-query-memory-mb" :integer . :max-query-memory-mb)
    ("--max-ingest-bytes" :integer . :max-ingest-bytes)
    ("--max-table-rows" :integer . :max-table-rows)
    ("--max-join-rows" :integer . :max-join-rows)
    ("--threads" :integer . :threads)
    ("--log-level" :string . :log-level)
    ("--native-kernels" :string . :native-kernels)
    ("--request" :string . :request)
    ;; serve-mode options
    ("--host" :string . :host)
    ("--port" :integer . :port)
    ("--workers" :integer . :workers)
    ("--queue-depth" :integer . :queue-depth)
    ("--query-timeout-ms" :integer . :query-timeout-ms)
    ("--shutdown-grace-ms" :integer . :shutdown-grace-ms)
    ("--max-request-bytes" :integer . :max-request-bytes)))

(defun parse-command-line (args)
  "Returns (values mode options-plist). Signals USAGE-ERROR."
  (let ((mode nil) (options '()))
    (loop while args do
      (let* ((arg (pop args))
             (eq-pos (and (> (length arg) 2) (string= "--" arg :end2 2) (position #\= arg)))
             (name (if eq-pos (subseq arg 0 eq-pos) arg))
             (inline-value (and eq-pos (subseq arg (1+ eq-pos))))
             (spec (assoc name *option-specs* :test #'string=)))
        (cond
          (spec
           (destructuring-bind (kind . key) (cdr spec)
             (if (eq kind :flag)
                 (progn
                   (when inline-value (usage-error "option ~A takes no value" name))
                   (setf (getf options key) t))
                 (let ((value (or inline-value
                                  (if args (pop args) (usage-error "option ~A requires a value" name)))))
                   (setf (getf options key)
                         (if (eq kind :integer)
                             (let ((n (parse-int-text value)))
                               (unless (and n (>= n 0))
                                 (usage-error "option ~A expects a non-negative integer" name))
                               n)
                             value))))))
          ((and (> (length arg) 1) (char= (char arg 0) #\-))
           (usage-error "unknown option ~A" arg))
          ((null mode) (setf mode arg))
          (t (usage-error "unexpected argument ~A" arg)))))
    (unless mode (usage-error "missing mode (version, capabilities, session, exec, serve)"))
    (values mode options)))

(defun current-directory ()
  (let ((cwd (sb-unix:posix-getcwd)))
    (if (and cwd (plusp (length cwd))) cwd ".")))

(defun ensure-trailing-slash (dir)
  (if (and (plusp (length dir)) (char= (char dir (1- (length dir))) #\/))
      dir
      (concatenate 'string dir "/")))

(defun make-config-from-options (options)
  (let ((data-dir (or (getf options :data-dir) (current-directory)))
        (log-level (or (getf options :log-level) "info")))
    (unless (member log-level '("debug" "info" "warn" "error" "off") :test #'string=)
      (usage-error "invalid log level ~A" log-level))
    (unless (char= (char (ensure-trailing-slash data-dir) 0) #\/)
      (setf data-dir (concatenate 'string (ensure-trailing-slash (current-directory)) data-dir)))
    (setf *log-level* (intern (string-upcase log-level) :keyword))
    (let ((config (make-engine-config :data-dir (ensure-trailing-slash data-dir)
                                      :test-functions (getf options :test-functions)
                                      :log-level *log-level*)))
      (macrolet ((opt (key accessor)
                   `(when (getf options ,key) (setf (,accessor config) (getf options ,key)))))
        (opt :max-query-memory-mb engine-config-max-query-memory-mb)
        (opt :max-ingest-bytes engine-config-max-ingest-bytes)
        (opt :max-table-rows engine-config-max-table-rows)
        (opt :max-join-rows engine-config-max-join-rows)
        (opt :threads engine-config-threads))
      config)))

(defun make-server-options-from (options)
  "SERVER-OPTIONS for `serve` from the parsed command line options."
  (unless (getf options :port)
    (usage-error "serve requires --port N"))
  (when (> (getf options :port) 65535)
    (usage-error "invalid port ~D" (getf options :port)))
  (let ((server-options (make-server-options :port (getf options :port))))
    (macrolet ((opt (key accessor)
                 `(when (getf options ,key) (setf (,accessor server-options) (getf options ,key)))))
      (opt :host server-options-host)
      (opt :queue-depth server-options-queue-depth)
      (opt :query-timeout-ms server-options-query-timeout-ms)
      (opt :shutdown-grace-ms server-options-shutdown-grace-ms)
      (opt :max-request-bytes server-options-max-request-bytes))
    ;; --workers 0 means "the default" (one per CPU)
    (when (and (getf options :workers) (plusp (getf options :workers)))
      (setf (server-options-workers server-options) (getf options :workers)))
    server-options))

;;; ------------------------------------------------------------------
;;; Modes

(defun write-response-line (response stream)
  (write-json response stream)
  (write-char #\Newline stream)
  (force-output stream))

(defun handle-json-text (session text)
  "Parse TEXT as one request and handle it; malformed JSON is INVALID_REQUEST."
  (let ((request (handler-case (parse-json text)
                   (json-syntax-error (e)
                     (return-from handle-json-text
                       (error-response :null "INVALID_REQUEST"
                                       (format nil "malformed JSON: ~A" (json-syntax-error-message e))))))))
    (handle-request session request)))

(defun blank-line-p (line)
  (every (lambda (c) (member c '(#\Space #\Tab #\Return))) line))

(defun run-session (config in out)
  (let ((session (make-session config)))
    (log-message :debug "session started, data dir ~A" (engine-config-data-dir config))
    (loop for line = (read-line in nil nil)
          while line
          unless (blank-line-p line)
            do (write-response-line (handle-json-text session line) out))
    0))

(defun read-stream-text (stream)
  (with-output-to-string (s)
    (loop for line = (read-line stream nil nil)
          while line
          do (write-line line s))))

(defun run-exec (config request-source in out)
  (unless request-source (usage-error "exec requires --request FILE or --request -"))
  (let* ((text (if (string= request-source "-")
                   (read-stream-text in)
                   (handler-case
                       (with-open-file (s (sb-ext:parse-native-namestring request-source)
                                          :external-format '(:utf-8 :replacement #\?))
                         (read-stream-text s))
                     (file-error ()
                       (format *error-output* "cannot read request file ~A~%" request-source)
                       (return-from run-exec 1)))))
         (session (make-session config))
         (parsed (handler-case (parse-json text)
                   (json-syntax-error (e)
                     (write-response-line
                      (error-response :null "INVALID_REQUEST"
                                      (format nil "malformed JSON: ~A" (json-syntax-error-message e)))
                      out)
                     (return-from run-exec 0)))))
    (if (simple-vector-p parsed)
        (loop for request across parsed
              do (write-response-line (handle-request session request) out))
        (write-response-line (handle-request session parsed) out))
    0))

(defun run-mode (mode options in out)
  (cond
    ((string= mode "version")
     (write-response-line (version-response :omit) out) 0)
    ((string= mode "capabilities")
     (write-response-line (capabilities-response :omit) out) 0)
    ((string= mode "session")
     (run-session (make-config-from-options options) in out))
    ((string= mode "exec")
     (let ((config (make-config-from-options options)))
       (run-exec config (getf options :request) in out)))
    ((string= mode "serve")
     (let ((config (make-config-from-options options)))
       (run-server config (make-server-options-from options) out)))
    (t (usage-error "unknown mode ~A" mode))))

(defun main ()
  "Process entry point."
  (let ((in (sb-sys:make-fd-stream 0 :input t :buffering :full
                                     :external-format (list :utf-8 :replacement
                                                            (code-char #xFFFD))))
        (out (sb-sys:make-fd-stream 1 :output t :buffering :full :external-format :utf-8))
        (code 1))
    (handler-case
        (sb-int:with-float-traps-masked (:overflow :invalid :divide-by-zero :inexact :underflow)
          (multiple-value-bind (mode options) (parse-command-line (rest sb-ext:*posix-argv*))
            (setf code (run-mode mode options in out))))
      (usage-error (e)
        (format *error-output* "polyquery: ~A~%" (usage-error-message e))
        (setf code 2))
      (sb-int:broken-pipe ()
        (setf code 0))
      (sb-sys:interactive-interrupt ()
        (setf code 130))
      (error (e)
        (ignore-errors (format *error-output* "polyquery: fatal error: ~A~%" e))
        (setf code 1)))
    (ignore-errors (finish-output out))
    (ignore-errors (finish-output *error-output*))
    (sb-ext:exit :code code :abort t)))
