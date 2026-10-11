;;;; test-decimal38.lisp — DECIMAL precision 38 (change request CR-2,
;;;; spec/changes/decimal38.md): type domain and result precision W, literal
;;;; typing, exact arithmetic and comparisons, CAST, the 128-bit PQCF v2
;;;; codec and agreement of all execution options on wide decimals.

(in-package #:polyquery-tests)

;;; Types

(deftest decimal38.type-domain
    (list (type-name-string (parse-type-string "DECIMAL(38,10)" "X"))
          (type-name-string (parse-type-string "numeric(38, 38)" "X"))
          (code-of (parse-type-string "DECIMAL(39,0)" "INVALID_REQUEST"))
          (code-of (parse-type-string "DECIMAL(30,31)" "INVALID_REQUEST")))
  ("DECIMAL(38,10)" "DECIMAL(38,38)" "INVALID_REQUEST" "INVALID_REQUEST"))

(deftest decimal38.narrow-and-wide
    (mapcar (lambda (p) (polyquery::wide-decimal-type-p (polyquery::make-decimal-type p 0)))
            '(1 18 19 38))
  (nil nil t t))

(deftest decimal38.result-precision
    (list (polyquery::decimal-result-precision :int64 '(:decimal 18 2))
          (polyquery::decimal-result-precision '(:decimal 10 2) '(:decimal 19 0))
          (polyquery::common-numeric-type :int64 '(:decimal 5 2))
          (polyquery::common-numeric-type :int64 '(:decimal 25 2))
          (polyquery::common-numeric-type '(:decimal 25 2) :float64))
  (18 38 (:decimal 18 2) (:decimal 38 2) :float64))

(deftest decimal38.result-types
    (list (result-types "SELECT 12345678901234567890.5")
          (result-types "SELECT 0.12345678901234567890123456789012345678")
          (result-types "SELECT 123456789012345678901234567890123456789.0")
          (result-types "SELECT 1.5 + 2.25, CAST(1 AS DECIMAL(19,1)) + 2.25")
          (result-types "SELECT CAST(1 AS DECIMAL(20,10)) * CAST(1 AS DECIMAL(10,9)), 7 * CAST(1 AS DECIMAL(19,2))")
          (result-types "SELECT CAST(1 AS DECIMAL(38,20)) * CAST(1 AS DECIMAL(38,19))")
          (result-types "SELECT ROUND(CAST(1 AS DECIMAL(30,3)), 2), FLOOR(CAST(1 AS DECIMAL(30,1))), ABS(CAST(1 AS DECIMAL(25,2)))")
          (result-types "SELECT SUM(CAST(v AS DECIMAL(10,2))), SUM(CAST(v AS DECIMAL(38,2))), AVG(CAST(v AS DECIMAL(38,2))) FROM t")
          (result-types "SELECT CAST(1 AS DECIMAL(39,0))"))
  (("DECIMAL(21,1)") ("DECIMAL(38,38)") ("FLOAT64") ("DECIMAL(18,2)" "DECIMAL(38,2)")
   ("DECIMAL(38,19)" "DECIMAL(38,2)") "TYPE_ERROR" ("DECIMAL(38,2)" "DECIMAL(38,0)" "DECIMAL(25,2)")
   ("DECIMAL(18,2)" "DECIMAL(38,2)" "FLOAT64") "SEMANTIC_ERROR"))

;;; Values (DECIMAL results are unscaled integers)

(deftest decimal38.arithmetic
    (list (query-rows "SELECT CAST('99999999999999999999999999999999999998' AS DECIMAL(38,0)) + 1")
          (query-rows "SELECT CAST('99999999999999999999999999999999999998' AS DECIMAL(38,0)) + 2")
          (query-rows "SELECT 9223372036854775807 + CAST(1 AS DECIMAL(19,0))")
          (query-rows "SELECT CAST('12345678901234567890' AS DECIMAL(20,0)) * CAST('12345678901234567' AS DECIMAL(20,0))")
          (query-rows "SELECT 999999999999999999 + 1.0"))
  (((99999999999999999999999999999999999999)) "NUMERIC_OVERFLOW" ((9223372036854775808))
   ((152415787532388356514250977776253630)) "NUMERIC_OVERFLOW"))

(deftest decimal38.exact-comparison
    (query-rows "SELECT 9223372036854775807 > 1.5, 9223372036854775807 = 9223372036854775807.0,
                        CAST('0.1' AS DECIMAL(38,37)) = 0.1, 9223372036854775807 IN (1.5, 9223372036854775807.00)")
  ((t t t t)))

(deftest decimal38.cast
    (list (query-rows "SELECT CAST(CAST('-12345.99' AS DECIMAL(30,2)) AS INT64)")
          (query-rows "SELECT CAST(CAST('9223372036854775808' AS DECIMAL(20,0)) AS INT64)")
          (query-rows "SELECT CAST(0.1e0 AS DECIMAL(38,30))")
          (query-rows "SELECT CAST(CAST('-1.25' AS DECIMAL(30,2)) AS DECIMAL(30,1)), CAST(CAST('-0.0000000001' AS DECIMAL(38,10)) AS STRING)"))
  (((-12345)) "NUMERIC_OVERFLOW" ((100000000000000005551115123126)) ((-13 "-0.0000000001"))))

(deftest decimal38.sum-overflow
    (list (query-rows "SELECT SUM(x) FROM (SELECT CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0)) AS x
                                           UNION ALL SELECT CAST(-1 AS DECIMAL(38,0))) d")
          (query-rows "SELECT SUM(x) FROM (SELECT CAST('99999999999999999999999999999999999999' AS DECIMAL(38,0)) AS x
                                           UNION ALL SELECT CAST(1 AS DECIMAL(38,0))) d"))
  (((99999999999999999999999999999999999998)) "NUMERIC_OVERFLOW"))

(deftest decimal38.alias-future-keyword
    (mapcar #'polyquery::column-def-name
            (polyquery::query-result-columns (execute-sql (fixture-session) "SELECT 1 AS full, 2 AS Right")))
  ("full" "Right"))

;;; PQCF v2

(deftest decimal38.i128-codec
    (let ((buf (polyquery::make-octets 16)))
      (loop for v in (list 0 -1 1 (1- (expt 10 38)) (- 1 (expt 10 38)) (expt 2 64) (- (expt 2 63)))
            always (progn (setf (polyquery::octets-i128 buf 0) v)
                          (= v (polyquery::octets-i128 buf 0)))))
  t)

(defun wide-table ()
  (polyquery::make-table "w"
                         (list (polyquery::make-column-def "id" :int64)
                               (polyquery::make-column-def "amt" (polyquery::make-decimal-type 38 10))
                               (polyquery::make-column-def "small" (polyquery::make-decimal-type 10 2)))
                         (list (vector 1 2 3 4 5)
                               (vector (1- (expt 10 38)) :null (- 1 (expt 10 38)) 5 5)
                               (vector 125 :null -375 0 0))
                         5))

(defun pqcf-header-version (table)
  (let* ((dir (temp-dir))
         (path (concatenate 'string dir "t.pqcf")))
    (unwind-protect
         (progn
           (polyquery::write-file-atomically
            path (lambda (stream) (polyquery::write-pqcf stream table '())))
           (with-open-file (in path :element-type '(unsigned-byte 8))
             (file-position in 4)
             (read-byte in)))
      (uiop:delete-directory-tree (pathname dir) :validate t))))

(deftest decimal38.pqcf-writer-version
    (list (pqcf-header-version (wide-table)) (pqcf-header-version (int-table '(1 2 3))))
  (2 1))

(deftest decimal38.pqcf-roundtrip
    (let ((table (wide-table)))
      (loop for encoding in '(:auto :plain :rle)
            always (loop for size in '(2 65536)
                         always (loop for reopened in (save-and-reopen table :encoding encoding
                                                                             :row-group-size size)
                                      always (loop for k below 3
                                                   always (equalp (polyquery::table-column-values table k)
                                                                  (polyquery::table-column-values reopened k)))))))
  t)

;;; Execution options

(defun wide-csv (n)
  (with-output-to-string (s)
    (write-line "id,k,w,n,b" s)
    (dotimes (i n)
      (format s "~D,~D,~A,~A,~A~%" i (mod i 7)
              (if (zerop (mod i 13)) "" (format nil "~D.~10,'0D" (* (- (mod (* i 7919) 2000) 1000) (expt 10 (mod i 19))) (mod (* i 31) 10000000000)))
              (if (zerop (mod i 11)) "" (format nil "~D.~2,'0D" (- (mod (* i 37) 1000) 500) (mod i 100)))
              (if (zerop (mod i 17)) "" (* (- (mod i 9) 4) (expt 10 (mod i 27))))))))

(defun wide-session ()
  (let ((session (make-session (make-engine-config :data-dir "/nonexistent/"))))
    (handle-request session (jobj "op" "load" "table" "g" "format" "csv" "data" (wide-csv 2000)
                                  "schema" (list (jobj "name" "id" "type" "INT64") (jobj "name" "k" "type" "INT64")
                                                 (jobj "name" "w" "type" "DECIMAL(38,10)")
                                                 (jobj "name" "n" "type" "DECIMAL(12,2)")
                                                 (jobj "name" "b" "type" "DECIMAL(30,0)"))))
    session))

(defparameter *wide-queries*
  '("SELECT k, COUNT(w), SUM(w), MIN(w), MAX(w), AVG(w), SUM(b), COUNT(DISTINCT b) FROM g GROUP BY k"
    "SELECT w, COUNT(*) FROM g GROUP BY w"
    "SELECT id, w + n, w - n, n * b, -w, ABS(b), ROUND(w, 2), FLOOR(w) FROM g WHERE id < 500"
    "SELECT id FROM g WHERE w > n AND b >= k"
    "SELECT id FROM g WHERE b > 9223372036854775807 OR w = 0.5 OR b IN (1, 10, 100000000000000000000.0)"
    "SELECT a.id, c.id FROM g a JOIN g c ON a.b = c.k WHERE a.id < 300"
    "SELECT a.id, c.id FROM g a JOIN g c ON a.w = c.w AND a.id < c.id"
    "SELECT id, w FROM g ORDER BY w DESC NULLS FIRST, id LIMIT 25"
    "SELECT DISTINCT b FROM g"
    "SELECT w FROM g WHERE id < 30 UNION ALL SELECT n FROM g WHERE id < 30 UNION ALL SELECT k FROM g WHERE id < 30"
    "SELECT id, CASE WHEN k > 3 THEN w ELSE n END, COALESCE(w, b) FROM g WHERE id < 400"))

(deftest decimal38.modes-agree
    (let ((*phase5-session* (wide-session)))
      (remove-if #'same-in-all-modes *wide-queries*))
  nil)
