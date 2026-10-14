;;;; test-statement.lisp — statement CSV records, dates, amounts, merchants.

(in-package #:pqledger-tests)

(defun date-of (text format)
  (let ((days (pqledger::parse-statement-date text format)))
    (and days (pq:date-string days))))

(deftest date.formats
    (list (date-of "2026-09-30" :iso) (date-of "20260930" :compact) (date-of "9/3/2026" :us)
          (date-of "09/03/2026" :eu-slash) (date-of "3.9.2026" :eu-dot))
  ("2026-09-30" "2026-09-30" "2026-09-03" "2026-03-09" "2026-09-03"))

(deftest date.invalid
    (list (date-of "2026-02-30" :iso) (date-of "2026-9-30" :iso) (date-of "9/3/26" :us)
          (date-of "13/01/2026" :us) (date-of "0000-01-01" :iso) (date-of "2026/09/30" :iso)
          (date-of "123/1/2026" :us))
  (nil nil nil nil nil nil nil))

(defun amount-of (text &rest settings)
  (pqledger::parse-amount-text text (apply #'pqledger::make-import-settings settings)))

(deftest amount.signed
    (list (amount-of " -12.50 ") (amount-of "+3") (amount-of "(4.5)") (amount-of "0.07")
          (amount-of "-0.00"))
  (-1250 300 -450 7 0))

(deftest amount.symbols
    (list (amount-of "$1,234.56" :currency-symbol "$" :thousands-separator #\,)
          (amount-of "($31.06)" :currency-symbol "$")
          (amount-of "-1.120,00 €" :currency-symbol "€" :thousands-separator #\. :decimal-separator #\,)
          (amount-of "1 000,5" :thousands-separator #\Space :decimal-separator #\,))
  (123456 -3106 -112000 100050))

(deftest amount.invalid
    (list (amount-of "1.234") (amount-of "abc") (amount-of "") (amount-of "1,00")
          (amount-of "--1") (amount-of "12345678901234567") (amount-of ".5"))
  (nil nil nil nil nil nil nil))

(deftest merchant.examples
    (mapcar #'pqledger::normalize-merchant
            (list "Whole Foods Market #10234" (format nil "SQ *Blue  Bottle~C4421" #\Tab) "Rent 2026"
                  "7-Eleven 12" "#123" "Shop 12 345" "REI #" "  café  " ""))
  ("WHOLE FOODS MARKET" "SQ *BLUE BOTTLE" "RENT" "7-ELEVEN 12" "#123" "SHOP 12" "REI #" "CAFé" ""))

(deftest csv.records
    (pqledger::parse-csv-records (coerce (format nil "a,b~%~%\"x~%y\",\"q\"\"\"~C~%,~%" #\Return)
                                         'simple-string)
                                 0 1 #\, "f")
  ((1 . #("a" "b")) (3 . #(#.(format nil "x~%y") "q\"")) (5 . #("" ""))))

(deftest csv.records.lines
    (mapcar #'car (pqledger::parse-csv-records (coerce (format nil "p~%q~%a~%b") 'simple-string)
                                               (pqledger::skip-physical-lines
                                                (format nil "p~%q~%a~%b") 2)
                                               3 #\, "f"))
  (3 4))

(deftest csv.bad-quote
    (status-of (pqledger::parse-csv-records (coerce "\"a\"b,c" 'simple-string) 0 1 #\, "f"))
  4)

(defun statement-entries (text &rest settings)
  (let ((path (write-file (format nil "~Astatement.csv" (temporary-directory)) text)))
    (mapcar (lambda (e) (list (pqledger::entry-line e) (pq:date-string (pqledger::entry-date e))
                              (pqledger::entry-cents e) (pqledger::entry-merchant e)))
            (pqledger::read-statement path "s.csv"
                                      (apply #'pqledger::make-import-settings settings)))))

(deftest statement.debit-credit
    (statement-entries (format nil "pre~%DATE;Text;Soll;Haben~%01.02.2026;Rent;1.000,00;~%02.02.2026;Pay;;50~%")
                       :delimiter #\; :skip-lines 1 :date-format :eu-dot :description-column "text"
                       :amount-mode :debit-credit :debit-column "Soll" :credit-column "Haben"
                       :decimal-separator #\, :thousands-separator #\.)
  ((3 "2026-02-01" -100000 "RENT") (4 "2026-02-02" 5000 "PAY")))

(deftest statement.errors
    (list (status-of (statement-entries (format nil "Date,Description,Amount~%2026-01-01,x~%")))
          (status-of (statement-entries (format nil "Day,Description,Amount~%2026-01-01,x,1~%")))
          (status-of (statement-entries (format nil "Date,Description,Debit,Credit~%2026-01-01,x,,~%")
                                        :amount-mode :debit-credit))
          (status-of (statement-entries (format nil "x,2026-01-01~%") :header nil :date-column 2
                                        :description-column 1 :amount-column 3))
          (status-of (statement-entries (format nil "x,2026-01-01,1~%") :header nil)))
  (4 4 4 4 2))

(deftest statement.invert
    (statement-entries (format nil "Date,Description,Amount~%2026-01-01,a,5~%2026-01-02,b,(1)~%")
                       :invert-sign t)
  ((2 "2026-01-01" -500 "A") (3 "2026-01-02" 100 "B")))
