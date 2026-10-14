;;;; config.lisp — the configuration file (pqledger.md §3): locating, the
;;;; INI-style line syntax shared with the rules and budget files, and the
;;;; validated settings.

(in-package #:pqledger)

;;; ------------------------------------------------------------------
;;; Line syntax (§3.2)

(defun unquote-value (value)
  "VALUE with surrounding double quotes removed and \\\" and \\\\ unescaped,
if it is quoted; otherwise VALUE itself."
  (if (and (>= (length value) 2)
           (char= (char value 0) #\")
           (char= (char value (1- (length value))) #\"))
      (with-output-to-string (out)
        (loop with i = 1
              with end = (1- (length value))
              while (< i end)
              do (let ((c (char value i)))
                   (if (and (char= c #\\) (< (1+ i) end)
                            (member (char value (1+ i)) '(#\" #\\)))
                       (progn (write-char (char value (1+ i)) out) (incf i 2))
                       (progn (write-char c out) (incf i))))))
      value))

(defun map-ini-lines (function text file &key sections)
  "Call FUNCTION for every meaningful line of TEXT with (LINE-NUMBER KIND A B):
KIND :SECTION with A the section name (only if SECTIONS is true), or
:ASSIGNMENT with A the key and B the unquoted value. Malformed lines are
configuration errors naming FILE and the line."
  (loop for raw in (split-lines text)
        for number from 1
        for line = (trim-blanks raw)
        do (cond ((zerop (length line)))
                 ((member (char line 0) '(#\# #\;)))
                 ((and sections (char= (char line 0) #\[))
                  (unless (char= (char line (1- (length line))) #\])
                    (config-error "~A:~D: malformed section header" file number))
                  (funcall function number :section (subseq line 1 (1- (length line))) nil))
                 ((position #\= line)
                  (let* ((pos (position #\= line))
                         (key (trim-blanks (subseq line 0 pos)))
                         (value (unquote-value (trim-blanks (subseq line (1+ pos))))))
                    (when (zerop (length key))
                      (config-error "~A:~D: missing key before '='" file number))
                    (funcall function number :assignment key value)))
                 (t (config-error "~A:~D: expected KEY = VALUE" file number)))))

(defun read-text-file-or-fail (path description failure)
  "The UTF-8 text of the file at PATH; FAILURE (a signalling function) is
called if it cannot be read or is not UTF-8."
  (let ((octets (file-octets path)))
    (unless octets
      (funcall failure "cannot read ~A ~A" description path))
    (or (decode-utf-8 octets)
        (funcall failure "~A ~A is not valid UTF-8" description path))))

;;; ------------------------------------------------------------------
;;; Settings

(defstruct import-settings
  "How the bank CSV files of one account are read (§3.3 `[import]`)."
  (delimiter #\,)
  (header t)
  (skip-lines 0)
  (date-column "Date")                  ; a column reference: position (integer) or name
  (date-format :iso)                    ; :ISO :COMPACT :US :EU-SLASH :EU-DOT
  (description-column "Description")
  (amount-mode :signed)                 ; :SIGNED or :DEBIT-CREDIT
  (amount-column "Amount")
  (debit-column "Debit")
  (credit-column "Credit")
  (decimal-separator #\.)
  (thousands-separator nil)             ; NIL (none) or a character
  (currency-symbol "")
  (invert-sign nil))

(defstruct config
  "A validated configuration file."
  (path "")
  (data-dir "")                         ; absolute native paths
  (rules-file nil)
  (budget-file nil)
  (format :table)
  (threads nil)
  (memory-mb nil)
  (import-values '())                   ; alist (slot-keyword . value) of [import]
  (account-values '()))                 ; alist (account-name . alist) of [account NAME]

(defparameter *date-formats*
  '(("YYYY-MM-DD" . :iso) ("YYYYMMDD" . :compact) ("MM/DD/YYYY" . :us)
    ("DD/MM/YYYY" . :eu-slash) ("DD.MM.YYYY" . :eu-dot)))

(defun parse-boolean-value (v)
  (cond ((string= v "true") (values t t))
        ((string= v "false") (values nil t))
        (t (values nil nil))))

(defun parse-column-reference (v)
  "A positive integer position, or a header name; NIL if V is empty."
  (cond ((zerop (length v)) nil)
        ((and (digits-p v) (plusp (parse-integer v))) (parse-integer v))
        (t v)))

(defun parse-import-value (key v)
  "The parsed value of the [import] KEY's text V as (values slot value ok)."
  (macrolet ((result (slot form) `(multiple-value-bind (value ok) ,form (values ,slot value ok))))
    (cond
      ((string= key "delimiter")
       (result :delimiter (cond ((string= v "tab") (values #\Tab t))
                                ((and (= (length v) 1) (< (char-code (char v 0)) 128)
                                      (not (member (char v 0) '(#\" #\Return #\Newline))))
                                 (values (char v 0) t))
                                (t (values nil nil)))))
      ((string= key "header") (result :header (parse-boolean-value v)))
      ((string= key "invert_sign") (result :invert-sign (parse-boolean-value v)))
      ((string= key "skip_lines")
       (result :skip-lines (let ((n (parse-digits v))) (values n (and n t)))))
      ((member key '("date_column" "description_column" "amount_column" "debit_column"
                     "credit_column") :test #'string=)
       (let ((ref (parse-column-reference v)))
         (values (intern (substitute #\- #\_ (string-upcase key)) :keyword) ref (and ref t))))
      ((string= key "date_format")
       (result :date-format (let ((f (cdr (assoc v *date-formats* :test #'string=))))
                              (values f (and f t)))))
      ((string= key "amount_mode")
       (result :amount-mode (cond ((string= v "signed") (values :signed t))
                                  ((string= v "debit_credit") (values :debit-credit t))
                                  (t (values nil nil)))))
      ((string= key "decimal_separator")
       (result :decimal-separator (if (member v '("." ",") :test #'string=)
                                      (values (char v 0) t)
                                      (values nil nil))))
      ((string= key "thousands_separator")
       (result :thousands-separator
               (cond ((string= v "none") (values nil t))
                     ((string= v "space") (values #\Space t))
                     ((member v '("," "." "'") :test #'string=) (values (char v 0) t))
                     (t (values nil nil)))))
      ((string= key "currency_symbol") (values :currency-symbol v t))
      (t (values nil nil :unknown)))))

(defun apply-import-values (settings values)
  "Set the slots of the IMPORT-SETTINGS SETTINGS named in the alist VALUES."
  (loop for (slot . value) in values
        do (ecase slot
             (:delimiter (setf (import-settings-delimiter settings) value))
             (:header (setf (import-settings-header settings) value))
             (:skip-lines (setf (import-settings-skip-lines settings) value))
             (:date-column (setf (import-settings-date-column settings) value))
             (:date-format (setf (import-settings-date-format settings) value))
             (:description-column (setf (import-settings-description-column settings) value))
             (:amount-mode (setf (import-settings-amount-mode settings) value))
             (:amount-column (setf (import-settings-amount-column settings) value))
             (:debit-column (setf (import-settings-debit-column settings) value))
             (:credit-column (setf (import-settings-credit-column settings) value))
             (:decimal-separator (setf (import-settings-decimal-separator settings) value))
             (:thousands-separator (setf (import-settings-thousands-separator settings) value))
             (:currency-symbol (setf (import-settings-currency-symbol settings) value))
             (:invert-sign (setf (import-settings-invert-sign settings) value))))
  settings)

(defun account-settings (config account)
  "The effective IMPORT-SETTINGS of ACCOUNT: its [account] values, else the
[import] values, else the defaults."
  (let ((settings (make-import-settings)))
    (apply-import-values settings (config-import-values config))
    (apply-import-values settings (cdr (assoc account (config-account-values config)
                                              :test #'string=)))))

(defun check-separators (settings file where)
  (when (eql (import-settings-decimal-separator settings)
             (import-settings-thousands-separator settings))
    (config-error "~A: ~A: decimal_separator and thousands_separator must differ" file where)))

;;; ------------------------------------------------------------------
;;; Parsing a configuration file

(defparameter *ledger-keys* '("data_dir" "rules_file" "budget_file"))

(defun section-kind (name)
  "The section kind of a header NAME (:LEDGER ... or (:ACCOUNT name)), or NIL."
  (cond ((string= name "ledger") :ledger)
        ((string= name "import") :import)
        ((string= name "output") :output)
        ((string= name "engine") :engine)
        ((and (starts-with-p "account " name) (account-name-p (subseq name 8)))
         (list :account (subseq name 8)))))

(defun parse-config (text path)
  "Parse and validate the configuration TEXT read from the absolute PATH."
  (let ((config (make-config :path path))
        (base (directory-of path))
        (section nil)
        (seen-sections '())
        (seen-keys '())
        (ledger-values '())
        (import-values '())
        (account-values '()))
    (flet ((invalid (number key value)
             (config-error "~A:~D: invalid value ~S for ~A" path number value key)))
      (map-ini-lines
       (lambda (number kind a b)
         (ecase kind
           (:section
            (let ((kind (section-kind a)))
              (unless kind
                (config-error "~A:~D: unknown section [~A]" path number a))
              (when (member kind seen-sections :test #'equal)
                (config-error "~A:~D: section [~A] appears twice" path number a))
              (push kind seen-sections)
              (setf section kind seen-keys '())))
           (:assignment
            (let ((key a) (value b))
              (unless section
                (config-error "~A:~D: assignment outside a section" path number))
              (when (member key seen-keys :test #'string=)
                (config-error "~A:~D: key ~A repeated in its section" path number key))
              (push key seen-keys)
              (cond
                ((eq section :ledger)
                 (unless (member key *ledger-keys* :test #'string=)
                   (config-error "~A:~D: unknown key ~A in [ledger]" path number key))
                 (when (zerop (length value))
                   (invalid number key value))
                 (push (cons key (absolute-path value base)) ledger-values))
                ((eq section :output)
                 (unless (string= key "format")
                   (config-error "~A:~D: unknown key ~A in [output]" path number key))
                 (setf (config-format config)
                       (or (output-format-keyword value) (invalid number key value))))
                ((eq section :engine)
                 (unless (member key '("threads" "memory_mb") :test #'string=)
                   (config-error "~A:~D: unknown key ~A in [engine]" path number key))
                 (let ((n (parse-digits value)))
                   (unless (and n (plusp n))
                     (invalid number key value))
                   (if (string= key "threads")
                       (setf (config-threads config) n)
                       (setf (config-memory-mb config) n))))
                (t
                 (multiple-value-bind (slot parsed ok) (parse-import-value key value)
                   (when (eq ok :unknown)
                     (config-error "~A:~D: unknown key ~A" path number key))
                   (unless ok (invalid number key value))
                   (if (eq section :import)
                       (push (cons slot parsed) import-values)
                       (push (cons slot parsed)
                             (cdr (or (assoc (second section) account-values :test #'string=)
                                      (first (push (list (second section)) account-values)))))))))))))
       text path :sections t))
    (unless (member :ledger seen-sections)
      (config-error "~A: missing section [ledger]" path))
    (let ((data-dir (cdr (assoc "data_dir" ledger-values :test #'string=))))
      (unless data-dir
        (config-error "~A: [ledger] data_dir is required" path))
      (setf (config-data-dir config) (if (ends-with-p "/" data-dir)
                                         data-dir
                                         (concatenate 'string data-dir "/"))
            (config-rules-file config) (cdr (assoc "rules_file" ledger-values :test #'string=))
            (config-budget-file config) (cdr (assoc "budget_file" ledger-values :test #'string=))
            (config-import-values config) (reverse import-values)
            (config-account-values config)
            (loop for (name . values) in account-values collect (cons name (reverse values)))))
    (check-separators (account-settings config "") path "[import]")
    (loop for (name) in (config-account-values config)
          do (check-separators (account-settings config name) path
                               (format nil "[account ~A]" name)))
    config))

(defun output-format-keyword (name)
  "The output format keyword named NAME, or NIL."
  (cdr (assoc name '(("table" . :table) ("csv" . :csv) ("json" . :json)) :test #'string=)))

(defun locate-config (option-path)
  "The absolute path of the configuration file (§3.1): OPTION-PATH (from
--config), else $PQLEDGER_CONFIG if non-empty, else ./pqledger.conf."
  (let ((env (sb-posix:getenv "PQLEDGER_CONFIG")))
    (absolute-path (cond (option-path)
                         ((and env (plusp (length env))) env)
                         (t "pqledger.conf"))
                   (current-directory))))

(defun load-config (option-path)
  "Locate, read and validate the configuration."
  (let ((path (locate-config option-path)))
    (parse-config (read-text-file-or-fail path "configuration file" #'config-error) path)))
