;;;; statement.lisp — reading bank statement CSV exports (pqledger.md §6.2,
;;;; §6.3): CSV records with their physical line numbers, column references,
;;;; date and amount conversion, merchant normalization.

(in-package #:pqledger)

(defstruct (entry (:constructor make-entry (line date cents description merchant)))
  "One converted statement record: the physical LINE it starts on, the DATE
(days since 1970-01-01), the amount in CENTS, the trimmed DESCRIPTION and the
normalized MERCHANT."
  line date cents description merchant)

;;; ------------------------------------------------------------------
;;; CSV records

(defun skip-physical-lines (text count)
  "The index in TEXT after its first COUNT physical lines."
  (let ((start 0))
    (loop repeat count
          for pos = (position #\Newline text :start start)
          do (if pos
                 (setf start (1+ pos))
                 (return-from skip-physical-lines (length text))))
    start))

(defun parse-csv-records (text start first-line delimiter file)
  "The CSV records of TEXT from index START, which is on physical line
FIRST-LINE: a list of (LINE . FIELDS), LINE being the physical line the record
starts on and FIELDS a simple-vector of strings. Empty lines are skipped.
Malformed quoting is an import error naming FILE and the line."
  (declare (type simple-string text) (type fixnum start first-line)
           (type character delimiter))
  (let ((records '())
        (n (length text))
        (i start)
        (line first-line)
        (field (make-string-output-stream)))
    (declare (type fixnum n i line))
    (flet ((at (k) (if (< k n) (schar text k) nil))
           (line-end-p (k)
             (or (>= k n)
                 (char= (schar text k) #\Newline)
                 (and (char= (schar text k) #\Return) (< (1+ k) n)
                      (char= (schar text (1+ k)) #\Newline)))))
      (loop while (< i n) do
        (let ((record-line line)
              (fields '()))
          (cond
            ;; an empty line
            ((char= (schar text i) #\Newline) (incf i) (incf line))
            ((and (char= (schar text i) #\Return) (eql (at (1+ i)) #\Newline))
             (incf i 2) (incf line))
            (t
             (loop
               (if (eql (at i) #\")
                   ;; quoted field
                   (progn
                     (incf i)
                     (loop
                       (let ((c (at i)))
                         (cond ((null c)
                                (import-error "~A:~D: unterminated quoted field" file record-line))
                               ((char/= c #\")
                                (when (char= c #\Newline) (incf line))
                                (write-char c field) (incf i))
                               ((eql (at (1+ i)) #\")
                                (write-char #\" field) (incf i 2))
                               (t (incf i) (return)))))
                     (unless (or (line-end-p i) (char= (schar text i) delimiter))
                       (import-error "~A:~D: unexpected character after a closing quote"
                                     file record-line)))
                   ;; unquoted field
                   (loop until (or (line-end-p i) (char= (schar text i) delimiter))
                         do (write-char (schar text i) field) (incf i)))
               (push (get-output-stream-string field) fields)
               (cond ((>= i n) (return))
                     ((char= (schar text i) delimiter) (incf i))
                     ((char= (schar text i) #\Newline) (incf i) (incf line) (return))
                     (t (incf i 2) (incf line) (return))))
             (push (cons record-line (coerce (nreverse fields) 'simple-vector)) records))))))
    (nreverse records)))

;;; ------------------------------------------------------------------
;;; Field conversion

(defun parse-statement-date (text format)
  "The DATE value (days) of the trimmed date TEXT in FORMAT, or NIL."
  (flet ((ymd (y m d)
           (and y m d (valid-date-p y m d) (pq:make-date y m d)))
         (number (s min-digits max-digits)
           (and (<= min-digits (length s) max-digits) (digits-p s) (parse-integer s))))
    (ecase format
      (:iso (and (= (length text) 10) (char= (char text 4) #\-) (char= (char text 7) #\-)
                 (ymd (number (subseq text 0 4) 4 4) (number (subseq text 5 7) 2 2)
                      (number (subseq text 8 10) 2 2))))
      (:compact (and (= (length text) 8) (digits-p text)
                     (ymd (parse-integer text :end 4) (parse-integer text :start 4 :end 6)
                          (parse-integer text :start 6))))
      ((:us :eu-slash :eu-dot)
       (let ((parts (loop with sep = (if (eq format :eu-dot) #\. #\/)
                          with start = 0
                          for pos = (position sep text :start start)
                          collect (subseq text start pos)
                          while pos
                          do (setf start (1+ pos)))))
         (and (= (length parts) 3)
              (let ((a (number (first parts) 1 2))
                    (b (number (second parts) 1 2))
                    (y (number (third parts) 4 4)))
                (if (eq format :us) (ymd y a b) (ymd y b a)))))))))

(defun parse-amount-text (text settings)
  "The amount in cents of an amount field TEXT converted as in §6.2 step 3
(without invert_sign), or NIL if it is malformed."
  (let ((s (trim-blanks text))
        (negative nil)
        (currency (import-settings-currency-symbol settings))
        (thousands (import-settings-thousands-separator settings)))
    (cond ((and (>= (length s) 2) (char= (char s 0) #\() (char= (char s (1- (length s))) #\)))
           (setf negative t s (subseq s 1 (1- (length s)))))
          ((starts-with-p "-" s) (setf negative t s (subseq s 1)))
          ((starts-with-p "+" s) (setf s (subseq s 1))))
    (when (plusp (length currency))
      (cond ((starts-with-p currency s) (setf s (subseq s (length currency))))
            ((ends-with-p currency s) (setf s (subseq s 0 (- (length s) (length currency)))))))
    (setf s (trim-blanks s))
    (when thousands
      (setf s (remove thousands s)))
    (when (char= (import-settings-decimal-separator settings) #\,)
      (setf s (substitute #\. #\, s)))
    (let ((cents (parse-budget-amount s)))
      (and cents (if negative (- cents) cents)))))

(defun normalize-merchant (description)
  "The merchant of DESCRIPTION (§6.3): ASCII letters upper-cased, runs of
spaces and tabs collapsed to one space, trimmed, and a trailing store number
token (#digits, or 3 or more digits) removed."
  (let* ((collapsed (with-output-to-string (out)
                      (let ((pending nil))
                        (loop for c across description
                              do (if (blank-char-p c)
                                     (setf pending t)
                                     (progn
                                       (when pending (write-char #\Space out) (setf pending nil))
                                       (write-char (if (char<= #\a c #\z) (char-upcase c) c) out)))))))
         (merchant (string-left-trim " " collapsed))
         (space (position #\Space merchant :from-end t)))
    (if (and space
             (let ((token-start (1+ space)) (end (length merchant)))
               (or (and (< token-start end) (char= (char merchant token-start) #\#)
                        (digits-p merchant :start (1+ token-start)))
                   (and (>= (- end token-start) 3) (digits-p merchant :start token-start)))))
        (subseq merchant 0 space)
        merchant)))

;;; ------------------------------------------------------------------
;;; Reading a statement

(defun resolve-column (reference header-fields file what settings)
  "The 0-based index of the column REFERENCE (a position or a header name)."
  (etypecase reference
    (integer (1- reference))
    (string
     (unless (import-settings-header settings)
       (config-error "~A: column ~S is a name, which requires header = true" what reference))
     (or (position reference header-fields
                   :test (lambda (name field) (ascii-string-equal name (trim-blanks field))))
         (import-error "~A: the header has no column ~S (~A)" file reference what)))))

(defun read-statement (path file settings)
  "The ENTRYs of the bank statement at the native PATH (FILE is the name used
in messages), read with the IMPORT-SETTINGS SETTINGS, in file order."
  (let* ((octets (or (file-octets path) (import-error "~A: cannot read the file" file)))
         (text (coerce (or (decode-utf-8 octets) (import-error "~A: the file is not valid UTF-8" file))
                       'simple-string))
         (skip (import-settings-skip-lines settings))
         (start (skip-physical-lines text skip))
         (records (parse-csv-records text start (1+ skip) (import-settings-delimiter settings) file))
         (header (and (import-settings-header settings)
                      (or (pop records) (import-error "~A: the file has no header record" file))))
         (width (length (cdr (or header (first records) '(0 . #())))))
         (debit-credit (eq (import-settings-amount-mode settings) :debit-credit)))
    (flet ((column (reference what)
             (let ((k (resolve-column reference (and header (cdr header)) file what settings)))
               (when (and (>= k width) (or header records))
                 (import-error "~A:~D: column ~D (~A) is beyond the record's ~D fields"
                               file (car (or header (first records))) (1+ k) what width))
               k)))
      (let ((date-k (column (import-settings-date-column settings) "date_column"))
            (description-k (column (import-settings-description-column settings) "description_column"))
            (amount-k (and (not debit-credit)
                           (column (import-settings-amount-column settings) "amount_column")))
            (debit-k (and debit-credit (column (import-settings-debit-column settings) "debit_column")))
            (credit-k (and debit-credit
                           (column (import-settings-credit-column settings) "credit_column"))))
        (loop for (line . fields) in records
              collect (progn
                        (unless (= (length fields) width)
                          (import-error "~A:~D: the record has ~D fields, expected ~D"
                                        file line (length fields) width))
                        (convert-record fields line file settings
                                        date-k description-k amount-k debit-k credit-k)))))))

(defun convert-record (fields line file settings date-k description-k amount-k debit-k credit-k)
  "The ENTRY of one statement record."
  (flet ((fail (format-control &rest args)
           (import-error "~A:~D: ~?" file line format-control args))
         (amount (k what)
           (let ((text (svref fields k)))
             (or (parse-amount-text text settings)
                 (import-error "~A:~D: invalid ~A ~S" file line what text)))))
    (let* ((date-text (trim-blanks (svref fields date-k)))
           (date (or (parse-statement-date date-text (import-settings-date-format settings))
                     (fail "invalid date ~S" date-text)))
           (description (trim-blanks (svref fields description-k)))
           (cents (if amount-k
                      (amount amount-k "amount")
                      (let ((debit (trim-blanks (svref fields debit-k)))
                            (credit (trim-blanks (svref fields credit-k))))
                        (when (and (zerop (length debit)) (zerop (length credit)))
                          (fail "both debit and credit are empty"))
                        (- (if (zerop (length credit)) 0 (amount credit-k "credit"))
                           (if (zerop (length debit)) 0 (amount debit-k "debit")))))))
      (when (>= (abs cents) (expt 10 18))
        (fail "amount out of range"))
      (make-entry line date
                  (if (import-settings-invert-sign settings) (- cents) cents)
                  description
                  (normalize-merchant description)))))
