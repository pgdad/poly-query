;;;; lexer.lisp — SQL tokenizer (grammar.md §1).

(in-package #:polyquery)

(defparameter *reserved-keywords*
  '("ALL" "AND" "AS" "ASC" "BETWEEN" "BY" "CASE" "CAST" "CREATE" "CROSS" "DATE" "DESC"
    "DISTINCT" "DROP" "ELSE" "END" "EXISTS" "EXPLAIN" "FALSE" "FIRST" "FROM" "FULL"
    "GROUP" "HAVING" "IF" "IN" "INDEX" "INNER" "IS" "JOIN" "LAST" "LEFT" "LIKE" "LIMIT"
    "NOT" "NULL" "NULLS" "OFFSET" "ON" "OR" "ORDER" "OUTER" "RIGHT" "SELECT" "THEN"
    "TIMESTAMP" "TRUE" "UNION" "USING" "WHEN" "WHERE" "WITH"))

(defparameter *keyword-table*
  (let ((h (make-hash-table :test 'equal)))
    (dolist (k *reserved-keywords* h)
      (setf (gethash k h) (intern k :keyword)))))

(defstruct (token (:constructor make-token (kind value line column &optional text)))
  "KIND is one of :KEYWORD (VALUE a keyword symbol, TEXT the word as
written), :IDENT (VALUE the name), :QIDENT (quoted identifier), :INTEGER /
:NUMBER (VALUE the literal text), :STRING, :OP (VALUE an operator string) or
:EOF."
  kind value text
  (line 1 :type fixnum)
  (column 1 :type fixnum))

(defun parse-error-at (line column format-control &rest args)
  (error 'pq-error :code "PARSE_ERROR"
                   :message (format nil "~?, at line ~D column ~D" format-control args line column)
                   :details (list (cons "line" line) (cons "column" column))))

(defun ident-start-char-p (c)
  (or (char<= #\a c #\z) (char<= #\A c #\Z) (char= c #\_)))

(defun ident-char-p (c)
  (or (ident-start-char-p c) (digit-char-p* c)))

(defun tokenize (sql)
  "Split SQL text into a vector of tokens terminated by an :EOF token."
  (let ((tokens '()) (i 0) (n (length sql)) (line 1) (line-start 0))
    (labels ((peek (&optional (k 0))
               (let ((j (+ i k))) (if (< j n) (char sql j) nil)))
             (col () (1+ (- i line-start)))
             (advance ()
               (when (char= (char sql i) #\Newline)
                 (incf line) (setf line-start (1+ i)))
               (incf i))
             (emit (kind value tline tcol &optional text)
               (push (make-token kind value tline tcol text) tokens))
             (scan-quoted (quote-char what tline tcol)
               ;; I points at the opening quote.
               (advance)
               (let ((out (make-string-output-stream)))
                 (loop
                   (when (>= i n)
                     (parse-error-at tline tcol "unterminated ~A" what))
                   (let ((c (char sql i)))
                     (cond ((char= c quote-char)
                            (if (eql (peek 1) quote-char)
                                (progn (write-char c out) (advance) (advance))
                                (progn (advance) (return))))
                           (t (write-char c out) (advance)))))
                 (get-output-stream-string out)))
             (scan-digits ()
               (loop while (and (peek) (digit-char-p* (peek))) do (advance))))
      (loop
        (let ((c (peek)))
          (cond
            ((null c) (return))
            ((member c '(#\Space #\Tab #\Newline #\Return)) (advance))
            ((and (char= c #\-) (eql (peek 1) #\-))
             (loop while (and (peek) (char/= (peek) #\Newline)) do (advance)))
            ((and (char= c #\/) (eql (peek 1) #\*))
             (let ((tline line) (tcol (col)))
               (advance) (advance)
               (loop
                 (when (>= i n) (parse-error-at tline tcol "unterminated block comment"))
                 (when (and (char= (char sql i) #\*) (eql (peek 1) #\/))
                   (advance) (advance) (return))
                 (advance))))
            ((ident-start-char-p c)
             (let ((start i) (tline line) (tcol (col)))
               (loop while (and (peek) (ident-char-p (peek))) do (advance))
               (let* ((word (subseq sql start i))
                      (kw (gethash (ascii-upcase word) *keyword-table*)))
                 (if kw
                     (emit :keyword kw tline tcol word)
                     (emit :ident word tline tcol)))))
            ((char= c #\")
             (let* ((tline line) (tcol (col))
                    (name (scan-quoted #\" "quoted identifier" tline tcol)))
               (when (zerop (length name))
                 (parse-error-at tline tcol "empty quoted identifier"))
               (emit :qident name tline tcol)))
            ((char= c #\')
             (let ((tline line) (tcol (col)))
               (emit :string (scan-quoted #\' "string literal" tline tcol) tline tcol)))
            ((or (digit-char-p* c) (and (char= c #\.) (peek 1) (digit-char-p* (peek 1))))
             (let ((start i) (tline line) (tcol (col)) (integral t))
               (scan-digits)
               (when (eql (peek) #\.)
                 (setf integral nil)
                 (advance)
                 (scan-digits))
               (when (and (member (peek) '(#\e #\E))
                          (or (and (peek 1) (digit-char-p* (peek 1)))
                              (and (member (peek 1) '(#\+ #\-)) (peek 2) (digit-char-p* (peek 2)))))
                 (setf integral nil)
                 (advance)
                 (when (member (peek) '(#\+ #\-)) (advance))
                 (scan-digits))
               (when (and (peek) (ident-char-p (peek)))
                 (parse-error-at tline tcol "invalid numeric literal"))
               (emit (if integral :integer :number) (subseq sql start i) tline tcol)))
            (t
             (let* ((tline line) (tcol (col))
                    (two (and (peek 1) (coerce (list c (peek 1)) 'string)))
                    (op (cond ((member two '("<=" ">=" "<>" "!=" "||") :test #'equal) two)
                              ((find c "+-*/%=<>(),.;") (string c))
                              (t nil))))
               (unless op
                 (parse-error-at tline tcol "unexpected character ~S" c))
               (dotimes (k (length op)) (advance))
               (emit :op op tline tcol))))))
      (push (make-token :eof nil line (col)) tokens)
      (coerce (nreverse tokens) 'simple-vector))))
