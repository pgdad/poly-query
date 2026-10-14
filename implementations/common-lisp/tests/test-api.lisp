;;;; test-api.lisp — the embedding API (package POLYQUERY.API).

(in-package #:polyquery-tests)

(defun api-error-code (thunk)
  (handler-case (progn (funcall thunk) :no-error)
    (polyquery.api:engine-error (e) (polyquery.api:engine-error-code e))))

(defun api-temp-dir ()
  (let ((dir (format nil "/tmp/polyquery-api-test-~D-~D/" (sb-posix:getpid) (random 1000000000))))
    (ensure-directories-exist dir)
    dir))

(deftest api.query.values
    (polyquery.api:with-database (db)
      (let ((r (polyquery.api:query
                db "SELECT 1 AS i, CAST('-12.50' AS DECIMAL(18,2)) AS d, 0.5e0 AS f, 'x' AS s,
                           TRUE AS b, DATE '1970-01-02' AS dt, NULL AS n")))
        (list (polyquery.api:result-column-names r) (polyquery.api:result-column-types r)
              (polyquery.api:result-row-count r)
              (coerce (svref (polyquery.api:result-rows r) 0) 'list)
              (polyquery.api:result-value r 0 "D"))))
  (("i" "d" "f" "s" "b" "dt" "n")
   ("INT64" "DECIMAL(18,2)" "FLOAT64" "STRING" "BOOLEAN" "DATE" "STRING")
   1
   (1 -25/2 0.5d0 "x" t 1 :null)
   -25/2))

(deftest api.load-text
    (polyquery.api:with-database (db)
      (list (multiple-value-bind (rows columns)
                (polyquery.api:load-csv db "t" :text (format nil "a;b~%1;x~%2;y~%") :delimiter ";")
              (list rows (mapcar #'polyquery.api:column-name columns)
                    (mapcar #'polyquery.api:column-type columns)))
            (polyquery.api:load-csv db "t" :text (format nil "1,2.50~%") :header nil :replace t
                                           :schema '(("k" "INT64") ("v" "DECIMAL(10,2)")))
            (mapcar #'polyquery.api:column-type (polyquery.api:table-schema db "t"))
            (polyquery.api:list-tables db)))
  ((2 ("a" "b") ("INT64" "STRING")) 1 ("INT64" "DECIMAL(10,2)") ("t")))

(deftest api.errors
    (polyquery.api:with-database (db)
      (list (api-error-code (lambda () (polyquery.api:query db "SELEC 1")))
            (api-error-code (lambda () (polyquery.api:query db "SELECT * FROM nowhere")))
            (api-error-code (lambda () (polyquery.api:drop-table db "nowhere")))
            (api-error-code (lambda () (polyquery.api:save-table db "t" "../x.pqcf")))
            (api-error-code (lambda () (polyquery.api:load-csv db "t" :text "a" :path "x")))
            ;; the instance stays usable after errors
            (polyquery.api:result-value (polyquery.api:query db "SELECT 2") 0 0)))
  ("PARSE_ERROR" "SEMANTIC_ERROR" "NOT_FOUND" "ACCESS_DENIED" "INVALID_REQUEST" 2))

(deftest api.closed
    (let ((db (polyquery.api:make-database)))
      (polyquery.api:close-database db)
      (polyquery.api:close-database db)
      (list (polyquery.api:database-open-p db)
            (api-error-code (lambda () (polyquery.api:query db "SELECT 1")))))
  (nil "INVALID_REQUEST"))

(deftest api.create-save-open
    (let ((dir (api-temp-dir)))
      (polyquery.api:with-database (db :data-dir dir :threads 2)
        (polyquery.api:create-table db "x" '(("id" "INT64") ("amount" "DECIMAL(18,2)") ("day" "DATE")
                                             ("note" "STRING"))
                                    (list (list 1 21/2 (polyquery.api:make-date 2026 1 1) "a")
                                          (vector 2 polyquery.api:+null+ 0 "")))
        (polyquery.api:save-table db "x" "x.pqcf")
        (polyquery.api:open-table db "y" "x.pqcf")
        (list (map 'list (lambda (row) (coerce row 'list))
                   (polyquery.api:result-rows (polyquery.api:query db "SELECT * FROM y ORDER BY id")))
              (api-error-code (lambda () (polyquery.api:open-table db "y" "x.pqcf")))
              (polyquery.api:open-table db "y" "x.pqcf" :replace t)
              (api-error-code (lambda ()
                                (polyquery.api:create-table db "z" '(("d" "DECIMAL(18,2)"))
                                                            (list (list 1/1000))))))))
  (((1 21/2 20454 "a") (2 :null 0 ""))
   "ALREADY_EXISTS" 2 "CONVERSION_ERROR"))

(deftest api.value-text
    (list (polyquery.api:value-text -1/2 "DECIMAL(18,2)") (polyquery.api:value-text 0 "DATE")
          (polyquery.api:value-text :null "INT64") (polyquery.api:decimal-string 1/3 2)
          (multiple-value-list (polyquery.api:date-components (polyquery.api:make-date 2024 2 29))))
  ("-0.50" "1970-01-01" nil "0.33" (2024 2 29)))
