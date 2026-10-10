;;;; json.lisp — strict RFC 8259 JSON reader and a compact writer.
;;;;
;;;; Representation of parsed JSON values:
;;;;   null -> :NULL        true -> :TRUE        false -> :FALSE
;;;;   string -> STRING     array -> SIMPLE-VECTOR
;;;;   object -> JSON-OBJECT (ordered list of (key . value) pairs)
;;;;   number -> INTEGER when written without '.', 'e' or 'E';
;;;;             otherwise a JNUM that keeps the literal text (exactness is
;;;;             needed for DECIMAL ingestion and for echoing request ids).
;;;;
;;;; The writer additionally accepts CL lists (arrays), DOUBLE-FLOATs and
;;;; JSON-RAW objects (a closure writing pre-formatted JSON).

(in-package #:polyquery)

(defstruct (json-object (:constructor %make-json-object (pairs)))
  (pairs nil :type list))

(defstruct (jnum (:constructor make-jnum (text)))
  (text "" :type string))

(defstruct (json-raw (:constructor make-json-raw (writer)))
  (writer nil :type function))

(defun jobj (&rest keys-and-values)
  "Build a JSON-OBJECT from alternating keys and values, skipping pairs whose
value is the marker :OMIT."
  (%make-json-object
   (loop for (k v) on keys-and-values by #'cddr
         unless (eq v :omit) collect (cons k v))))

(defun json-get (object key &optional default)
  "Look up KEY (case-sensitive) in a JSON-OBJECT. Returns (values value found-p)."
  (if (json-object-p object)
      (let ((cell (assoc key (json-object-pairs object) :test #'string=)))
        (if cell (values (cdr cell) t) (values default nil)))
      (values default nil)))

;;; ------------------------------------------------------------------
;;; Reader

(define-condition json-syntax-error (error)
  ((message :initarg :message :reader json-syntax-error-message)
   (position :initarg :position :reader json-syntax-error-position))
  (:report (lambda (c s)
             (format s "~A at offset ~D" (json-syntax-error-message c)
                     (json-syntax-error-position c)))))

(defconstant +json-max-depth+ 512)

(defun parse-json (text &key (start 0) (end (length text)) (duplicate-keys :first)
                          (allow-trailing nil))
  "Parse one JSON value from TEXT[START,END). Signals JSON-SYNTAX-ERROR.
DUPLICATE-KEYS is :FIRST (keep first), or :ERROR. Unless ALLOW-TRAILING, only
whitespace may follow the value. Returns (values value end-position)."
  (let ((s (if (typep text '(simple-array character (*))) text (coerce text '(simple-array character (*)))))
        (pos start))
    (declare (type (simple-array character (*)) s) (type fixnum pos end))
    (labels ((fail (msg) (error 'json-syntax-error :message msg :position pos))
             (skip-ws ()
               (loop while (and (< pos end)
                                (member (schar s pos) '(#\Space #\Tab #\Newline #\Return)))
                     do (incf pos)))
             (peek () (if (< pos end) (schar s pos) nil))
             (expect-literal (word value)
               (let ((e (+ pos (length word))))
                 (if (and (<= e end) (string= word s :start2 pos :end2 e))
                     (progn (setf pos e) value)
                     (fail "invalid literal"))))
             (parse-value (depth)
               (when (> depth +json-max-depth+) (fail "nesting too deep"))
               (skip-ws)
               (let ((c (peek)))
                 (case c
                   ((nil) (fail "unexpected end of input"))
                   (#\{ (parse-object depth))
                   (#\[ (parse-array depth))
                   (#\" (parse-string))
                   (#\t (expect-literal "true" :true))
                   (#\f (expect-literal "false" :false))
                   (#\n (expect-literal "null" :null))
                   (t (if (or (char= c #\-) (digit-char-p* c))
                          (parse-number)
                          (fail "unexpected character"))))))
             (parse-object (depth)
               (incf pos)
               (skip-ws)
               (let ((pairs '()))
                 (if (eql (peek) #\})
                     (incf pos)
                     (loop
                       (skip-ws)
                       (unless (eql (peek) #\") (fail "expected object key"))
                       (let ((key (parse-string)))
                         (skip-ws)
                         (unless (eql (peek) #\:) (fail "expected ':'"))
                         (incf pos)
                         (let ((value (parse-value (1+ depth))))
                           (if (assoc key pairs :test #'string=)
                               (when (eq duplicate-keys :error)
                                 (fail (format nil "duplicate key ~S" key)))
                               (push (cons key value) pairs))))
                       (skip-ws)
                       (case (peek)
                         (#\, (incf pos))
                         (#\} (incf pos) (return))
                         (t (fail "expected ',' or '}'")))))
                 (%make-json-object (nreverse pairs))))
             (parse-array (depth)
               (incf pos)
               (skip-ws)
               (let ((items '()))
                 (if (eql (peek) #\])
                     (incf pos)
                     (loop
                       (push (parse-value (1+ depth)) items)
                       (skip-ws)
                       (case (peek)
                         (#\, (incf pos))
                         (#\] (incf pos) (return))
                         (t (fail "expected ',' or ']'")))))
                 (coerce (nreverse items) 'simple-vector)))
             (hex4 ()
               (when (> (+ pos 4) end) (fail "truncated \\u escape"))
               (let ((v 0))
                 (dotimes (i 4 v)
                   (let ((d (digit-char-p (schar s (+ pos i)) 16)))
                     (unless d (fail "bad \\u escape"))
                     (setf v (+ (* v 16) d))))))
             (parse-string ()
               (incf pos)
               ;; Fast path: no escapes.
               (let ((stop (position-if (lambda (c) (or (char= c #\") (char= c #\\)
                                                        (char< c (code-char 32))))
                                        s :start pos :end end)))
                 (when (and stop (char= (schar s stop) #\"))
                   (return-from parse-string
                     (prog1 (subseq s pos stop) (setf pos (1+ stop))))))
               (let ((out (make-string-output-stream)))
                 (loop
                   (when (>= pos end) (fail "unterminated string"))
                   (let ((c (schar s pos)))
                     (cond ((char= c #\") (incf pos) (return))
                           ((char< c (code-char 32)) (fail "control character in string"))
                           ((char= c #\\)
                            (incf pos)
                            (when (>= pos end) (fail "unterminated escape"))
                            (let ((e (schar s pos)))
                              (incf pos)
                              (case e
                                (#\" (write-char #\" out))
                                (#\\ (write-char #\\ out))
                                (#\/ (write-char #\/ out))
                                (#\b (write-char (code-char 8) out))
                                (#\f (write-char (code-char 12) out))
                                (#\n (write-char (code-char 10) out))
                                (#\r (write-char (code-char 13) out))
                                (#\t (write-char (code-char 9) out))
                                (#\u
                                 (let ((cp (hex4)))
                                   (incf pos 4)
                                   (cond ((<= #xD800 cp #xDBFF)
                                          (unless (and (< (1+ pos) end)
                                                       (char= (schar s pos) #\\)
                                                       (char= (schar s (1+ pos)) #\u))
                                            (fail "lone surrogate"))
                                          (incf pos 2)
                                          (let ((lo (hex4)))
                                            (unless (<= #xDC00 lo #xDFFF) (fail "bad surrogate pair"))
                                            (incf pos 4)
                                            (write-char (code-char (+ #x10000 (ash (- cp #xD800) 10)
                                                                      (- lo #xDC00)))
                                                        out)))
                                         ((<= #xDC00 cp #xDFFF) (fail "lone surrogate"))
                                         (t (write-char (code-char cp) out)))))
                                (t (fail "invalid escape")))))
                           (t (write-char c out) (incf pos)))))
                 (get-output-stream-string out)))
             (parse-number ()
               (let ((begin pos) (integral t))
                 (when (eql (peek) #\-) (incf pos))
                 (cond ((eql (peek) #\0) (incf pos))
                       ((and (peek) (digit-char-p* (peek)))
                        (loop while (and (peek) (digit-char-p* (peek))) do (incf pos)))
                       (t (fail "invalid number")))
                 (when (eql (peek) #\.)
                   (setf integral nil)
                   (incf pos)
                   (unless (and (peek) (digit-char-p* (peek))) (fail "invalid number"))
                   (loop while (and (peek) (digit-char-p* (peek))) do (incf pos)))
                 (when (member (peek) '(#\e #\E))
                   (setf integral nil)
                   (incf pos)
                   (when (member (peek) '(#\+ #\-)) (incf pos))
                   (unless (and (peek) (digit-char-p* (peek))) (fail "invalid number"))
                   (loop while (and (peek) (digit-char-p* (peek))) do (incf pos)))
                 (if integral
                     (parse-integer s :start begin :end pos)
                     (make-jnum (subseq s begin pos))))))
      (let ((value (parse-value 0)))
        (skip-ws)
        (unless (or allow-trailing (= pos end))
          (fail "trailing characters after JSON value"))
        (values value pos)))))

;;; ------------------------------------------------------------------
;;; Writer

(defun write-json-string (string stream)
  (write-char #\" stream)
  (loop for c across string
        for code = (char-code c)
        do (cond ((char= c #\") (write-string "\\\"" stream))
                 ((char= c #\\) (write-string "\\\\" stream))
                 ((< code 32)
                  (case code
                    (10 (write-string "\\n" stream))
                    (13 (write-string "\\r" stream))
                    (9 (write-string "\\t" stream))
                    (8 (write-string "\\b" stream))
                    (12 (write-string "\\f" stream))
                    (t (format stream "\\u~4,'0X" code))))
                 (t (write-char c stream))))
  (write-char #\" stream))

(defun write-json (value stream)
  "Serialize VALUE as compact single-line JSON onto STREAM."
  (etypecase value
    ((eql :null) (write-string "null" stream))
    ((eql :true) (write-string "true" stream))
    ((eql :false) (write-string "false" stream))
    (string (write-json-string value stream))
    (integer (format stream "~D" value))
    (double-float (write-string (format-float value) stream))
    (jnum (write-string (jnum-text value) stream))
    (json-raw (funcall (json-raw-writer value) stream))
    (json-object
     (write-char #\{ stream)
     (loop for first = t then nil
           for (k . v) in (json-object-pairs value)
           do (unless first (write-char #\, stream))
              (write-json-string k stream)
              (write-char #\: stream)
              (write-json v stream))
     (write-char #\} stream))
    (list
     (write-char #\[ stream)
     (loop for first = t then nil
           for v in value
           do (unless first (write-char #\, stream))
              (write-json v stream))
     (write-char #\] stream))
    (simple-vector
     (write-char #\[ stream)
     (loop for i from 0
           for v across value
           do (unless (zerop i) (write-char #\, stream))
              (write-json v stream))
     (write-char #\] stream))))

(defun json-to-string (value)
  (with-output-to-string (s) (write-json value s)))
