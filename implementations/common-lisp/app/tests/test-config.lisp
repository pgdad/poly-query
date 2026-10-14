;;;; test-config.lisp — the configuration, rules and budget files.

(in-package #:pqledger-tests)

(defun config-from (text)
  (pqledger::parse-config text "/home/u/books/pqledger.conf"))

(defun config-status (text)
  (status-of (config-from text)))

(deftest config.unquote.1 (pqledger::unquote-value "\"  a \\\"b\\\" \\\\ \"") "  a \"b\" \\ ")
(deftest config.unquote.2 (pqledger::unquote-value "\"\"") "")
(deftest config.unquote.3 (pqledger::unquote-value "\"") "\"")

(deftest config.minimal
    (let ((c (config-from (format nil "~C~C; c~%[ledger]~%data_dir = data~%"
                                  #\Space #\Tab))))
      (list (pqledger::config-data-dir c) (pqledger::config-rules-file c)
            (pqledger::config-format c)))
  ("/home/u/books/data/" nil :table))

(deftest config.paths
    (let ((c (config-from (format nil "[ledger]~%data_dir = /abs/x/~%rules_file = ../r.conf~%"))))
      (list (pqledger::config-data-dir c) (pqledger::config-rules-file c)))
  ("/abs/x/" "/home/u/books/../r.conf"))

(deftest config.errors
    (mapcar #'config-status
            (list (format nil "data_dir = l~%[ledger]~%")
                  (format nil "[ledger]~%data_dir = l~%[ledger]~%")
                  (format nil "[ledger]~%data_dir = l~%data_dir = m~%")
                  (format nil "[ledger]~%rules_file = r~%")
                  (format nil "[import]~%header = true~%")
                  (format nil "[ledger]~%data_dir = l~%[output]~%format = xml~%")
                  (format nil "[ledger]~%data_dir = l~%[engine]~%threads = 0~%")
                  (format nil "[ledger]~%data_dir = l~%[account Bad]~%")
                  (format nil "[ledger]~%data_dir = l~%[import]~%skip_lines = -1~%")
                  (format nil "[ledger]~%data_dir = l~%[import]~%delimiter = ab~%")
                  (format nil "[ledger]~%data_dir = l~%[import]~%thousands_separator = .~%decimal_separator = .~%")
                  (format nil "[ledger]~%data_dir = l~%garbage~%")))
  (2 2 2 2 2 2 2 2 2 2 2 2))

(deftest config.account-settings
    (let* ((c (config-from (format nil "[ledger]~%data_dir = l~%[import]~%delimiter = ;~%skip_lines = 1~%~
                                        [account visa]~%delimiter = tab~%date_column = 2~%invert_sign = true~%")))
           (visa (pqledger::account-settings c "visa"))
           (other (pqledger::account-settings c "other")))
      (list (pqledger::import-settings-delimiter visa) (pqledger::import-settings-skip-lines visa)
            (pqledger::import-settings-date-column visa) (pqledger::import-settings-invert-sign visa)
            (pqledger::import-settings-delimiter other) (pqledger::import-settings-date-column other)))
  (#\Tab 1 2 t #\; "Date"))

(deftest rules.parse
    (mapcar (lambda (r) (list (pqledger::rule-number r) (pqledger::rule-category r)
                              (pqledger::rule-pattern r)))
            (pqledger::parse-rules (format nil "# x~%food = whole foods*, Café?~%~%travel = uber*~%food = rewe~%")
                                   "r"))
  ((1 "food" "WHOLE FOODS*") (2 "food" "CAFé?") (3 "travel" "UBER*") (4 "food" "REWE")))

(deftest rules.errors
    (mapcar (lambda (text) (status-of (pqledger::parse-rules text "r")))
            (list "food = SAFE_WAY" "food = 10%" "food = a,,b" "Food = a" "uncategorized = x"
                  "[x]" "food"))
  (2 2 2 2 2 2 2))

(deftest budgets.parse
    (pqledger::parse-budgets (format nil "food = 600~%fun = 30.5~%tax = 0.07~%") "b")
  (("food" . 60000) ("fun" . 3050) ("tax" . 7)))

(deftest budgets.errors
    (mapcar (lambda (text) (status-of (pqledger::parse-budgets text "b")))
            (list "food = 12.345" "food = -1" "food = 1e3" (format nil "a = 1~%a = 2")
                  "food = 12345678901234567"))
  (2 2 2 2 2))
