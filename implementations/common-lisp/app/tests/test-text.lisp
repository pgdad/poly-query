;;;; test-text.lisp — text utilities, names and months.

(in-package #:pqledger-tests)

(deftest text.trim (pqledger::trim-blanks (format nil " ~C a b ~C " #\Tab #\Tab)) "a b")
(deftest text.trim.newline-kept (pqledger::trim-blanks (format nil " a~%")) #.(format nil "a~%"))
(deftest text.upcase (pqledger::ascii-upcase "café x") "CAFé X")
(deftest text.lines (pqledger::split-lines (format nil "a~C~%b~%~%c" #\Return)) ("a" "b" "" "c"))
(deftest text.sql-string (pqledger::sql-string "it's") "'it''s'")

(deftest names.account (mapcar #'pqledger::account-name-p '("a" "giro-2_x" "Bad" "" "a b"))
  (t t nil nil nil))
(deftest names.account.long (pqledger::account-name-p (make-string 33 :initial-element #\a)) nil)
(deftest names.category (mapcar #'pqledger::category-name-p '("food" "uncategorized" "Food"))
  (t nil nil))

(deftest month.parse.1 (pqledger::parse-month "2026-09") (2026 . 9))
(deftest month.parse.2 (mapcar #'pqledger::parse-month '("2026-13" "0000-01" "2026-1" "26-01-01"))
  (nil nil nil nil))
(deftest month.last-day.leap (pqledger::month-last-day '(2024 . 2)) "2024-02-29")
(deftest month.last-day.century (pqledger::month-last-day '(1900 . 2)) "1900-02-28")
(deftest month.first-day (pqledger::month-first-day '(1 . 1)) "0001-01-01")
