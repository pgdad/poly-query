;;;; test-numbers.lisp — numeric text parsing/formatting and temporal values.

(in-package #:polyquery-tests)

(rem-all-tests)

(deftest float.format.1 (format-float 1000d0) "1000.0")
(deftest float.format.2 (format-float 0.1d0) "0.1")
(deftest float.format.3 (format-float -0d0) "0.0")
(deftest float.format.4 (format-float 1.5d300) "1.5e300")
(deftest float.format.5 (format-float 2.5d-300) "2.5e-300")
(deftest float.format.6 (format-float 1d-7) "1e-7")
(deftest float.format.7 (format-float 123.456d0) "123.456")

(deftest float.parse.1 (parse-float-text "1e3") 1000d0 :ok)
(deftest float.parse.2 (parse-float-text "-1.5e2") -150d0 :ok)
(deftest float.parse.3 (nth-value 1 (parse-float-text "1e400")) :overflow)
(deftest float.parse.4 (nth-value 1 (parse-float-text "NaN")) :syntax)
(deftest float.parse.5 (parse-float-text ".5") 0.5d0 :ok)
(deftest float.parse.6 (parse-float-text "0.30000000000000004") 0.30000000000000004d0 :ok)
(deftest float.parse.7 (= (parse-float-text "2.2250738585072014e-308") 2.2250738585072014d-308) t)

(deftest decimal.parse.1 (parse-decimal-text "-12.50") -1250 2)
(deftest decimal.parse.2 (parse-decimal-text "+7") 7 0)
(deftest decimal.parse.3 (parse-decimal-text "1e2") nil)
(deftest decimal.format.1 (format-decimal -50 2) "-0.50")
(deftest decimal.format.2 (format-decimal 12 0) "12")
(deftest decimal.format.3 (format-decimal 0 3) "0.000")

(deftest date.roundtrip.1 (format-date (parse-date-text "2024-02-29")) "2024-02-29")
(deftest date.roundtrip.2 (format-date (parse-date-text "0001-01-01")) "0001-01-01")
(deftest date.epoch (days-from-civil 1970 1 1) 0)
(deftest date.civil (multiple-value-list (civil-from-days -1)) (1969 12 31))
(deftest date.invalid.1 (parse-date-text "2023-02-29") nil)
(deftest date.invalid.2 (parse-date-text "2023-1-01") nil)
(deftest timestamp.format.1
    (format-timestamp (parse-timestamp-text "2024-02-29T13:14:15.5")) "2024-02-29 13:14:15.500000")
(deftest timestamp.format.2
    (format-timestamp (parse-timestamp-text "1969-12-31 23:59:59")) "1969-12-31 23:59:59")
(deftest timestamp.invalid (parse-timestamp-text "2023-01-01 25:00:00") nil)
(deftest timestamp.date-only (parse-timestamp-text "1970-01-02" :allow-date-only t) 86400000000)

(deftest type.parse.1 (type-name-string (parse-type-string "numeric(4, 1)" "X")) "DECIMAL(4,1)")
(deftest type.parse.2 (type-name-string (parse-type-string "BIGINT" "X")) "INT64")
(deftest type.parse.3 (type-name-string (parse-type-string "decimal" "X")) "DECIMAL(18,0)")
(deftest type.parse.4 (code-of (parse-type-string "DECIMAL(19,2)" "SEMANTIC_ERROR")) "SEMANTIC_ERROR")
