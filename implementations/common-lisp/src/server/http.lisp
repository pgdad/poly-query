;;;; http.lisp — a minimal HTTP/1.1 message layer (RFC 9112 subset) over
;;;; binary streams: request parsing (request line, headers, Content-Length
;;;; and chunked bodies, Expect: 100-continue), target decoding, and writing
;;;; of complete and chunked responses. It knows nothing about PolyQuery.

(in-package #:polyquery)

(defconstant +max-http-line+ 65536 "Longest accepted request/header line.")
(defconstant +max-http-headers+ 200)
(defconstant +http-discard-limit+ (* 64 1024 1024)
  "Oversized bodies up to this many bytes are read and discarded so the
connection survives; larger ones end the connection.")

(define-condition http-protocol-error (error)
  ((message :initarg :message :reader http-protocol-error-message))
  (:report (lambda (c s) (write-string (http-protocol-error-message c) s)))
  (:documentation "A malformed request; the connection cannot continue."))

(define-condition http-body-too-large (error)
  ((request :initarg :request :reader http-body-too-large-request)
   (drained :initarg :drained :reader http-body-too-large-drained
            :documentation "True if the whole body was consumed (the connection is reusable)."))
  (:report "request body too large"))

(defun http-protocol-error (format-control &rest args)
  (error 'http-protocol-error :message (apply #'format nil format-control args)))

(defstruct http-request
  (method "" :type string)
  (target "" :type string)
  (path "" :type string)                ; decoded path, without the query
  (segments '() :type list)             ; decoded, non-empty path segments
  (query '() :type list)                ; alist of decoded (name . value)
  (version "HTTP/1.1" :type string)
  (headers '() :type list)              ; alist of (lowercase-name . value)
  (body nil))                           ; octet vector or NIL

(defun http-header (request name)
  "The value of header NAME (lowercase) of REQUEST, or NIL."
  (cdr (assoc name (http-request-headers request) :test #'string=)))

(defun http-query-param (request name)
  (cdr (assoc name (http-request-query request) :test #'string=)))

(defun http-header-tokens (value)
  "The comma-separated, trimmed, lowercased tokens of a header VALUE."
  (when value
    (loop for token in (split-string value #\,)
          for trimmed = (string-trim '(#\Space #\Tab) token)
          unless (zerop (length trimmed)) collect (ascii-downcase trimmed))))

(defun http-keep-alive-p (request)
  "Whether the client wants the connection kept open after this exchange."
  (let ((tokens (http-header-tokens (http-header request "connection"))))
    (cond ((member "close" tokens :test #'string=) nil)
          ((string= (http-request-version request) "HTTP/1.0")
           (and (member "keep-alive" tokens :test #'string=) t))
          (t t))))

;;; ------------------------------------------------------------------
;;; Reading

(defun read-http-line (stream &key (eof-ok nil))
  "Read one CRLF (or LF) terminated line of octets as a Latin-1 string. At
end of input returns NIL if EOF-OK and nothing was read, else signals."
  (let ((buffer (make-array 128 :element-type 'character :adjustable t :fill-pointer 0)))
    (loop
      (let ((byte (read-byte stream nil nil)))
        (cond ((null byte)
               (if (and eof-ok (zerop (fill-pointer buffer)))
                   (return nil)
                   (http-protocol-error "unexpected end of request")))
              ((= byte 10)
               (let ((n (fill-pointer buffer)))
                 (when (and (plusp n) (char= (char buffer (1- n)) #\Return))
                   (decf (fill-pointer buffer))))
               (return (coerce buffer 'simple-string)))
              ((>= (fill-pointer buffer) +max-http-line+)
               (http-protocol-error "request line too long"))
              (t (vector-push-extend (code-char byte) buffer)))))))

(defun hex-digit-value (char)
  (digit-char-p char 16))

(defun percent-decode (string &key plus-as-space)
  "Decode %XX escapes (as UTF-8) in STRING; with PLUS-AS-SPACE, + is a space."
  (if (not (or (find #\% string) (and plus-as-space (find #\+ string))))
      string
      (let ((octets (make-array (length string) :element-type '(unsigned-byte 8)
                                                :fill-pointer 0)))
        (loop with i = 0
              while (< i (length string))
              do (let ((c (char string i)))
                   (cond ((and (char= c #\%) (< (+ i 2) (length string))
                               (hex-digit-value (char string (+ i 1)))
                               (hex-digit-value (char string (+ i 2))))
                          (vector-push (+ (* 16 (hex-digit-value (char string (+ i 1))))
                                          (hex-digit-value (char string (+ i 2))))
                                       octets)
                          (incf i 3))
                         ((and plus-as-space (char= c #\+))
                          (vector-push 32 octets) (incf i))
                         (t (vector-push (logand (char-code c) 255) octets) (incf i)))))
        (handler-case (sb-ext:octets-to-string (coerce octets '(vector (unsigned-byte 8)))
                                               :external-format :utf-8)
          (error () (http-protocol-error "invalid percent-encoding"))))))

(defun parse-query-string (query)
  (loop for pair in (split-string query #\&)
        unless (zerop (length pair))
          collect (let ((eq (position #\= pair)))
                    (if eq
                        (cons (percent-decode (subseq pair 0 eq) :plus-as-space t)
                              (percent-decode (subseq pair (1+ eq)) :plus-as-space t))
                        (cons (percent-decode pair :plus-as-space t) "")))))

(defun parse-request-target (request)
  "Fill in the path, segments and query of REQUEST from its target."
  (let* ((target (http-request-target request))
         ;; absolute-form (http://host/path) is accepted too
         (start (if (and (> (length target) 7) (string-equal "http://" target :end2 7))
                    (or (position #\/ target :start 7) (length target))
                    0))
         (qmark (position #\? target :start start))
         (raw-path (subseq target start (or qmark (length target)))))
    (setf (http-request-path request) (percent-decode raw-path)
          (http-request-segments request)
          (loop for segment in (split-string raw-path #\/)
                unless (zerop (length segment)) collect (percent-decode segment))
          (http-request-query request)
          (if qmark (parse-query-string (subseq target (1+ qmark))) '()))))

(defun parse-content-length (value)
  (let ((n (and value (every #'digit-char-p value) (plusp (length value))
                (parse-integer value))))
    (or n (http-protocol-error "invalid Content-Length"))))

(defun read-octets (stream n)
  "Read exactly N octets from STREAM."
  (let* ((buffer (make-array n :element-type '(unsigned-byte 8)))
         (got (read-sequence buffer stream)))
    (when (< got n) (http-protocol-error "unexpected end of request body"))
    buffer))

(defun discard-octets (stream n)
  (let ((buffer (make-array (min n 65536) :element-type '(unsigned-byte 8))))
    (loop while (plusp n)
          do (let ((got (read-sequence buffer stream :end (min n (length buffer)))))
               (when (zerop got) (http-protocol-error "unexpected end of request body"))
               (decf n got)))))

(defun read-chunked-body (stream request max-bytes)
  "Decode a chunked body. Beyond MAX-BYTES the data is discarded and
HTTP-BODY-TOO-LARGE is signalled at its end (or once the discard limit is hit)."
  (let ((out (make-array 1024 :element-type '(unsigned-byte 8) :adjustable t :fill-pointer 0))
        (total 0))
    (loop
      (let* ((line (read-http-line stream))
             (size-text (string-trim '(#\Space #\Tab)
                                     (subseq line 0 (or (position #\; line) (length line)))))
             (size (and (plusp (length size-text)) (every #'hex-digit-value size-text)
                        (parse-integer size-text :radix 16))))
        (unless size (http-protocol-error "invalid chunk size"))
        (when (zerop size)
          ;; trailer section
          (loop for trailer = (read-http-line stream)
                until (zerop (length trailer)))
          (return))
        (incf total size)
        (cond ((> total +http-discard-limit+)
               (error 'http-body-too-large :request request :drained nil))
              ((> total max-bytes) (discard-octets stream size))
              (t (let ((chunk (read-octets stream size)))
                   (loop for byte across chunk do (vector-push-extend byte out)))))
        (unless (zerop (length (read-http-line stream)))
          (http-protocol-error "missing CRLF after chunk data"))))
    (when (> total max-bytes)
      (error 'http-body-too-large :request request :drained t))
    (coerce out '(simple-array (unsigned-byte 8) (*)))))

(defun read-http-request (stream max-body-bytes &key on-continue)
  "Read the next request from STREAM. Returns NIL at a clean end of input.
ON-CONTINUE is called before reading a body the client is waiting to send
(Expect: 100-continue). Signals HTTP-PROTOCOL-ERROR or HTTP-BODY-TOO-LARGE."
  (let ((line (loop for l = (read-http-line stream :eof-ok t)
                    ;; tolerate empty lines before a request (RFC 9112 §2.2)
                    while (and l (zerop (length l)))
                    finally (return l))))
    (unless line (return-from read-http-request nil))
    (let ((parts (split-string line #\Space)))
      (unless (and (= (length parts) 3)
                   (plusp (length (first parts)))
                   (every #'upper-case-p (first parts))
                   (member (third parts) '("HTTP/1.1" "HTTP/1.0") :test #'string=))
        (http-protocol-error "malformed request line"))
      (let ((request (make-http-request :method (first parts) :target (second parts)
                                        :version (third parts))))
        (parse-request-target request)
        (setf (http-request-headers request)
              (loop for header = (read-http-line stream)
                    for count from 0
                    until (zerop (length header))
                    collect (let ((colon (position #\: header)))
                              (when (or (null colon) (zerop colon) (> count +max-http-headers+))
                                (http-protocol-error "malformed header"))
                              (cons (ascii-downcase (subseq header 0 colon))
                                    (string-trim '(#\Space #\Tab) (subseq header (1+ colon)))))))
        (let ((chunked (member "chunked" (http-header-tokens
                                          (http-header request "transfer-encoding"))
                               :test #'string=))
              (length (let ((v (http-header request "content-length")))
                        (and v (parse-content-length v))))
              (expect-continue (string-equal (http-header request "expect") "100-continue")))
          (cond
            (chunked
             (when (and expect-continue on-continue) (funcall on-continue))
             (setf (http-request-body request) (read-chunked-body stream request max-body-bytes)))
            ((and length (> length max-body-bytes))
             (if (and (<= length +http-discard-limit+) (not expect-continue))
                 (progn (discard-octets stream length)
                        (error 'http-body-too-large :request request :drained t))
                 (error 'http-body-too-large :request request :drained nil)))
            ((and length (plusp length))
             (when (and expect-continue on-continue) (funcall on-continue))
             (setf (http-request-body request) (read-octets stream length)))))
        request))))

;;; ------------------------------------------------------------------
;;; Writing
;;;
;;; Output bypasses SBCL's fd-streams, which queue whatever the kernel does
;;; not accept immediately: a response is assembled into one octet vector and
;;; written with blocking write(2) calls, so a client that stops reading
;;; blocks the writer (the basis of streaming backpressure).

(define-condition http-write-error (error)
  ((errno :initarg :errno :reader http-write-error-errno))
  (:report (lambda (c s)
             (format s "cannot write to the client: ~A"
                     (sb-int:strerror (http-write-error-errno c))))))

(defstruct (http-output (:constructor make-http-output (fd)))
  (fd -1 :type fixnum))

(defun write-octets (out octets)
  "Write all of OCTETS to the file descriptor of OUT, blocking as needed."
  (let ((fd (http-output-fd out))
        (octets (coerce octets '(simple-array (unsigned-byte 8) (*))))
        (start 0))
    (loop while (< start (length octets))
          do (multiple-value-bind (n errno)
                 (sb-sys:with-pinned-objects (octets)
                   (sb-unix:unix-write fd octets start (- (length octets) start)))
               (cond (n (incf start n))
                     ((= errno sb-unix:eintr))
                     ((= errno sb-unix:eagain) (sb-sys:wait-until-fd-usable fd :output))
                     (t (error 'http-write-error :errno errno)))))))

(defun octets-of (&rest parts)
  "Concatenate PARTS (strings, sent as UTF-8, or octet vectors) into octets."
  (let ((vectors (mapcar (lambda (p)
                           (if (stringp p) (sb-ext:string-to-octets p :external-format :utf-8) p))
                         parts)))
    (let ((result (make-array (reduce #'+ vectors :key #'length)
                              :element-type '(unsigned-byte 8)))
          (pos 0))
      (dolist (v vectors result)
        (replace result v :start1 pos)
        (incf pos (length v))))))

(defparameter *http-reason-phrases*
  '((100 . "Continue") (200 . "OK") (201 . "Created") (400 . "Bad Request")
    (403 . "Forbidden") (404 . "Not Found") (405 . "Method Not Allowed")
    (409 . "Conflict") (413 . "Content Too Large") (500 . "Internal Server Error")
    (503 . "Service Unavailable") (504 . "Gateway Timeout")))

(defparameter *crlf* (coerce '(#\Return #\Newline) 'string))

(defun header-safe-value (value)
  "VALUE with every octet outside printable ASCII percent-encoded, so a
client-chosen string can never break the header framing."
  (let ((octets (sb-ext:string-to-octets value :external-format :utf-8)))
    (if (every (lambda (b) (and (<= 32 b 126) (/= b 37))) octets)
        value
        (with-output-to-string (s)
          (loop for b across octets
                do (if (and (<= 32 b 126) (/= b 37))
                       (write-char (code-char b) s)
                       (format s "%~2,'0X" b)))))))

(defun status-and-headers (status headers)
  "The status line, HEADERS (alist of name . value) and the blank line."
  (with-output-to-string (s)
    (format s "HTTP/1.1 ~D ~A~A" status
            (or (cdr (assoc status *http-reason-phrases*)) "Unknown") *crlf*)
    (loop for (name . value) in headers
          do (format s "~A: ~A~A" name (header-safe-value (princ-to-string value)) *crlf*))
    (write-string *crlf* s)))

(defun write-continue (out)
  (write-octets out (octets-of (format nil "HTTP/1.1 100 Continue~A~A" *crlf* *crlf*))))

(defun write-http-response (out status content-type body &key headers (keep-alive t))
  "Write a complete response whose BODY is a string (sent as UTF-8) or octets."
  (let ((octets (if (stringp body)
                    (sb-ext:string-to-octets body :external-format :utf-8)
                    body)))
    (write-octets out
                  (octets-of (status-and-headers
                              status
                              (append (list (cons "Content-Type" content-type)
                                            (cons "Content-Length" (length octets))
                                            (cons "Connection" (if keep-alive "keep-alive" "close")))
                                      headers))
                             octets))))

(defun start-chunked-response (out status content-type &key headers (keep-alive t))
  (write-octets out
                (octets-of (status-and-headers
                            status
                            (append (list (cons "Content-Type" content-type)
                                          (cons "Transfer-Encoding" "chunked")
                                          (cons "Connection" (if keep-alive "keep-alive" "close")))
                                    headers)))))

(defun write-chunk (out string)
  "Send STRING (UTF-8) as one chunk."
  (let ((octets (sb-ext:string-to-octets string :external-format :utf-8)))
    (when (plusp (length octets))
      (write-octets out (octets-of (format nil "~X~A" (length octets) *crlf*) octets *crlf*)))))

(defun end-chunked-response (out)
  (write-octets out (octets-of (format nil "0~A~A" *crlf* *crlf*))))
