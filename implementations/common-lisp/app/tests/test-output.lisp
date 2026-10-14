;;;; test-output.lisp — value texts and the table, csv and json formats.

(in-package #:pqledger-tests)

(defun printed (report format)
  (with-output-to-string (out) (pqledger::write-report report format out)))

(defparameter *sample*
  (pqledger::make-report '("name" "amount" "n" "f" "ok")
                         '("STRING" "DECIMAL(18,2)" "INT64" "FLOAT64" "BOOLEAN")
                         (vector (vector "a, \"b\"" -25/2 3 0.5d0 t)
                                 (vector "" 0 pq:+null+ -1d-9 nil)
                                 (vector (format nil "tab~Cnl~%" #\Tab) 1000 12 1/3 pq:+null+))))

(deftest output.float
    (mapcar #'pqledger::format-fixed-6 '(0.5d0 -1d-9 2.5d-7 123456.1234565d0 -3d0 0.0078125d0 1d20))
  ("0.500000" "0.000000" "0.000000" "123456.123457" "-3.000000" "0.007812"
   "100000000000000000000.000000"))

(deftest output.table
    (printed (pqledger::make-report '("account" "balance") '("STRING" "DECIMAL(18,2)")
                                    (vector (vector "giro" -1201/100) (vector "x" pq:+null+)))
             :table)
  #.(format nil "account  balance~%-------  -------~%giro      -12.01~%x~%(2 rows)~%"))

(deftest output.table.one-row
    (printed (pqledger::make-report '("n") '("INT64") (vector (vector 7))) :table)
  #.(format nil "n~%-~%7~%(1 row)~%"))

(deftest output.csv (printed *sample* :csv)
  #.(format nil "name,amount,n,f,ok~%\"a, \"\"b\"\"\",-12.50,3,0.500000,true~%~
                 \"\",0.00,,0.000000,false~%\"tab~Cnl~%\",1000.00,12,0.333333,~%" #\Tab))

(deftest output.json (printed *sample* :json)
  #.(format nil "{\"name\":\"a, \\\"b\\\"\",\"amount\":\"-12.50\",\"n\":3,\"f\":0.500000,\"ok\":true}~%~
                 {\"name\":\"\",\"amount\":\"0.00\",\"n\":null,\"f\":0.000000,\"ok\":false}~%~
                 {\"name\":\"tab\\tnl\\n\",\"amount\":\"1000.00\",\"n\":12,\"f\":0.333333,\"ok\":null}~%"))

(deftest output.json.control
    (printed (pqledger::make-report '("s") '("STRING") (vector (vector (format nil "~C\\é" (code-char 1)))))
             :json)
  #.(format nil "{\"s\":\"\\u0001\\\\é\"}~%"))

(deftest output.json.empty (printed (pqledger::make-report '("s") '("STRING") #()) :json) "")
