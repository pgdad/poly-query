;;;; text.lisp — small text utilities: trimming, ASCII case, names, months,
;;;; reading UTF-8 files and SQL literals.

(in-package #:pqledger)

(declaim (inline blank-char-p ascii-digit-p))
(defun blank-char-p (c)
  "True for the characters pqledger trims: space and tab."
  (or (char= c #\Space) (char= c #\Tab)))

(defun ascii-digit-p (c)
  (char<= #\0 c #\9))

(defun trim-blanks (s)
  "S without leading and trailing spaces and tabs."
  (string-trim '(#\Space #\Tab) s))

(defun ascii-upcase (s)
  "S with the ASCII letters a-z upper-cased; other characters unchanged."
  (map 'string (lambda (c) (if (char<= #\a c #\z) (char-upcase c) c)) s))

(defun ascii-string-equal (a b)
  "ASCII case-insensitive string equality."
  (string= (ascii-upcase a) (ascii-upcase b)))

(defun digits-p (s &key (start 0) (end (length s)))
  "True if S[START,END) is a non-empty run of ASCII digits."
  (and (< start end)
       (loop for i from start below end always (ascii-digit-p (char s i)))))

(defun parse-digits (s)
  "The non-negative integer written as the ASCII digits S, or NIL."
  (and (digits-p s) (parse-integer s)))

(defun starts-with-p (prefix s)
  (and (<= (length prefix) (length s)) (string= prefix s :end2 (length prefix))))

(defun ends-with-p (suffix s)
  (and (<= (length suffix) (length s))
       (string= suffix s :start2 (- (length s) (length suffix)))))

;;; ------------------------------------------------------------------
;;; Names (pqledger.md §3.3)

(defun name-p (s)
  "True if S matches [a-z0-9_-]{1,32}."
  (and (<= 1 (length s) 32)
       (every (lambda (c) (or (char<= #\a c #\z) (ascii-digit-p c) (char= c #\_) (char= c #\-))) s)))

(defun account-name-p (s)
  (name-p s))

(defun category-name-p (s)
  (and (name-p s) (not (string= s "uncategorized"))))

;;; ------------------------------------------------------------------
;;; Months and dates

(defun leap-year-p (year)
  (and (zerop (mod year 4)) (or (plusp (mod year 100)) (zerop (mod year 400)))))

(defun days-in-month (year month)
  (case month
    (2 (if (leap-year-p year) 29 28))
    ((4 6 9 11) 30)
    (t 31)))

(defun valid-date-p (year month day)
  (and (<= 1 year 9999) (<= 1 month 12) (<= 1 day (days-in-month year month))))

(defun parse-month (s)
  "The (YEAR . MONTH) of a valid YYYY-MM text, or NIL."
  (when (and (= (length s) 7) (char= (char s 4) #\-)
             (digits-p s :end 4) (digits-p s :start 5))
    (let ((year (parse-integer s :end 4))
          (month (parse-integer s :start 5)))
      (and (<= 1 year 9999) (<= 1 month 12) (cons year month)))))

(defun month-first-day (month)
  "The first day of MONTH, a (YEAR . MONTH), as YYYY-MM-DD."
  (format nil "~4,'0D-~2,'0D-01" (car month) (cdr month)))

(defun month-last-day (month)
  "The last day of MONTH, a (YEAR . MONTH), as YYYY-MM-DD."
  (format nil "~4,'0D-~2,'0D-~2,'0D" (car month) (cdr month)
          (days-in-month (car month) (cdr month))))

(defun month< (a b)
  (or (< (car a) (car b)) (and (= (car a) (car b)) (< (cdr a) (cdr b)))))

;;; ------------------------------------------------------------------
;;; Files

(defun file-octets (path)
  "The contents of the file at the native PATH, or NIL if it cannot be read."
  (handler-case
      (with-open-file (in (sb-ext:parse-native-namestring path) :element-type '(unsigned-byte 8))
        (let* ((buffer (make-array (file-length in) :element-type '(unsigned-byte 8)))
               (n (read-sequence buffer in)))
          (if (= n (length buffer)) buffer (subseq buffer 0 n))))
    (error () nil)))

(defun decode-utf-8 (octets)
  "OCTETS decoded as UTF-8 without a leading BOM, or NIL if they are not UTF-8."
  (let ((start (if (and (>= (length octets) 3)
                        (= (aref octets 0) #xEF) (= (aref octets 1) #xBB) (= (aref octets 2) #xBF))
                   3 0)))
    (handler-case (sb-ext:octets-to-string octets :start start :external-format :utf-8)
      (error () nil))))

(defun split-lines (text)
  "The lines of TEXT, split at LF, each without its CR of a CRLF line end. A
final line end does not start another line."
  (let ((lines '()) (start 0) (n (length text)))
    (loop for pos = (position #\Newline text :start start)
          while pos
          do (push (subseq text start (if (and (> pos start) (char= (char text (1- pos)) #\Return))
                                          (1- pos) pos))
                   lines)
             (setf start (1+ pos)))
    (when (< start n)
      (push (subseq text start) lines))
    (nreverse lines)))

(defun directory-of (native-path)
  "The directory part (with a trailing slash) of the absolute NATIVE-PATH."
  (let ((slash (position #\/ native-path :from-end t)))
    (if slash (subseq native-path 0 (1+ slash)) "./")))

(defun base-name (native-path)
  "The last component of NATIVE-PATH."
  (let ((slash (position #\/ native-path :from-end t)))
    (if slash (subseq native-path (1+ slash)) native-path)))

(defun absolute-path (path base-directory)
  "PATH resolved against BASE-DIRECTORY (with a trailing slash) unless absolute."
  (if (and (plusp (length path)) (char= (char path 0) #\/))
      path
      (concatenate 'string base-directory path)))

(defun current-directory ()
  "The process's working directory, with a trailing slash."
  (let ((cwd (or (sb-unix:posix-getcwd) ".")))
    (if (ends-with-p "/" cwd) cwd (concatenate 'string cwd "/"))))

(defun file-exists-p (native-path)
  (and (probe-file (sb-ext:parse-native-namestring native-path)) t))

;;; ------------------------------------------------------------------
;;; SQL text

(defun sql-string (s)
  "S as an SQL string literal."
  (with-output-to-string (out)
    (write-char #\' out)
    (loop for c across s
          do (when (char= c #\') (write-char #\' out))
             (write-char c out))
    (write-char #\' out)))
