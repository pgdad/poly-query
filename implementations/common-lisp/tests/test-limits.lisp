;;;; test-limits.lisp — statement size limits (change request CR-6,
;;;; spec/changes/expression-limits.md): the three measures, RESOURCE_LIMIT
;;;; beyond them, linear processing of long chains in every execution mode,
;;;; deadlines in the early stages and stack exhaustion.

(in-package #:polyquery-tests)

(defun repeat-string (string count)
  (with-output-to-string (out)
    (dotimes (i count) (write-string string out))))

(defun joined (separator items)
  (with-output-to-string (out)
    (loop for (item . more) on items
          do (princ item out)
             (when more (write-string separator out)))))

(defun count-where (predicate)
  (format nil "SELECT count(*) FROM t WHERE ~A" predicate))

(defun first-cell-in-modes (sql)
  "The first cell of SQL's result in row, vectorized and parallel mode (one
list entry per mode), or the error codes."
  (let ((session (fixture-session)))
    (loop for options in (list (polyquery::make-exec-options :mode :row)
                               (polyquery::make-exec-options :mode :vectorized)
                               (polyquery::make-exec-options :mode :vectorized :threads 4))
          collect (handler-case
                      (svref (first (polyquery::query-result-rows
                                     (execute-sql session sql :options options)))
                             0)
                    (pq-error (e) (pq-error-code e))))))

(defun limit-error (sql)
  "(code message) of the error SQL fails with during parsing, or (:NO-ERROR)."
  (handler-case (progn (parse-sql sql) (list :no-error))
    (pq-error (e) (list (pq-error-code e) (polyquery::pq-error-message e)))))

;;; Measures

(deftest limits.utf-8-length
    (list (polyquery::utf-8-length "abc")
          (polyquery::utf-8-length (coerce (list (code-char #xE9) (code-char #x20AC)
                                                 (code-char #x1F600))
                                           'string)))
  (3 9))

(deftest limits.depth-minimum-parentheses
    (first-cell-in-modes (count-where (format nil "~A id >= 0 ~A"
                                              (repeat-string "(" 998) (repeat-string ")" 998))))
  (4 4 4))

(deftest limits.depth-minimum-functions-and-unary
    (first-cell-in-modes (count-where (format nil "~A id ~A >= 0 AND ~A id >= 0"
                                              (repeat-string "ABS(" 998) (repeat-string ")" 998)
                                              (repeat-string "- " 998))))
  (4 4 4))

(deftest limits.depth-minimum-not
    (first-cell-in-modes (count-where (format nil "~A id >= 0" (repeat-string "NOT " 998))))
  (4 4 4))

(deftest limits.depth-minimum-subqueries
    (first-cell-in-modes (format nil "SELECT ~A 1 ~A" (repeat-string "(SELECT " 998)
                                 (repeat-string ")" 998)))
  (1 1 1))

(deftest limits.depth-beyond
    (limit-error (count-where (format nil "~A id >= 0 ~A"
                                      (repeat-string "(" 5000) (repeat-string ")" 5000))))
  ("RESOURCE_LIMIT" "expression nesting depth exceeds 4096"))

(deftest limits.depth-beyond-subqueries
    (first (limit-error (format nil "SELECT ~A 1 ~A" (repeat-string "(SELECT " 5000)
                                (repeat-string ")" 5000))))
  "RESOURCE_LIMIT")

(deftest limits.chain-is-one-level
    ;; 20,000 levels if every operator counted; a chain counts once.
    (first-cell-in-modes (count-where (joined " OR " (loop for i below 20000
                                                           collect (format nil "id = ~D" i)))))
  (4 4 4))

(deftest limits.long-chains
    (list (first-cell-in-modes (format nil "SELECT max(id~A) FROM t" (repeat-string " + 1" 24998)))
          (first-cell-in-modes (count-where (joined " AND " (loop for i from 1 to 10000
                                                                  collect (format nil "id <> -~D" i)))))
          (first-cell-in-modes (count-where (format nil "id IN (~A)"
                                                    (joined ", " (loop for i below 24999 collect i)))))
          (first-cell-in-modes (format nil "SELECT max(length(s~A)) FROM t" (repeat-string " || 'a'" 10000))))
  ((25002 25002 25002) (4 4 4) (4 4 4) (10001 10001 10001)))

(deftest limits.wide-case-and-aggregates
    (list (first-cell-in-modes
           (format nil "SELECT sum(CASE ~A ELSE 0 END) FROM t"
                   (joined " " (loop for i below 5000 collect (format nil "WHEN id = ~D THEN ~D" i i)))))
          (first-cell-in-modes
           (format nil "SELECT ~A FROM t" (joined ", " (loop for i below 3000
                                                             collect (format nil "sum(v + ~D)" i))))))
  ((10 10 10) (100 100 100)))

(deftest limits.constant-chain-folds
    (first-cell-in-modes (format nil "SELECT 1~A" (repeat-string " + 1" 20000)))
  (20001 20001 20001))

(deftest limits.operands-beyond
    (let ((polyquery::*max-operands* 1000))
      (list (first (limit-error (count-where (format nil "id IN (~A)"
                                                     (joined ", " (loop for i below 998 collect i))))))
            (limit-error (count-where (format nil "id IN (~A)"
                                              (joined ", " (loop for i below 999 collect i)))))))
  ;; `*`, id and 998 items are exactly the limit; one more item exceeds it
  (:no-error ("RESOURCE_LIMIT" "operand count exceeds 1000")))

(deftest limits.text-beyond
    (let ((polyquery::*max-statement-bytes* 4000))
      (list (first (limit-error (format nil "SELECT '~A'" (make-string 3900 :initial-element #\a))))
            (first (limit-error (format nil "SELECT '~A'" (make-string 4000 :initial-element #\a))))
            ;; bytes, not characters: 1,500 two-byte characters
            (first (limit-error (format nil "SELECT '~A'"
                                        (make-string 1500 :initial-element (code-char #xE9)))))
            (first (limit-error (format nil "SELECT '~A'"
                                        (make-string 2000 :initial-element (code-char #xE9)))))))
  (:no-error "RESOURCE_LIMIT" :no-error "RESOURCE_LIMIT"))

(deftest limits.size-check-precedes-syntax-errors
    ;; Beyond a limit, RESOURCE_LIMIT may be reported instead of PARSE_ERROR.
    (first (limit-error (format nil "SELECT ~A 1 ~A FROM" (repeat-string "(" 5000)
                                (repeat-string ")" 5000))))
  "RESOURCE_LIMIT")

;;; The timeout covers parsing and analysis

(deftest limits.timeout-while-parsing
    (let ((polyquery::*query-context*
            (polyquery::make-query-context :deadline (1- (get-internal-real-time)))))
      (code-of (parse-sql (count-where (joined " OR " (loop for i below 10000
                                                            collect (format nil "id = ~D" i)))))))
  "TIMEOUT")

(deftest limits.timeout-counts-from-receipt
    ;; The deadline counts from the receipt of the request, not from the
    ;; start of execution.
    (let ((polyquery::*request-received* (- (get-internal-real-time)
                                            (* 2 internal-time-units-per-second))))
      (code-of (execute-sql (fixture-session) "SELECT 1" :timeout-ms 1000)))
  "TIMEOUT")

(deftest limits.constant-folding-keeps-timeout
    (let ((polyquery::*query-context*
            (polyquery::make-query-context :deadline (1- (get-internal-real-time)))))
      (code-of (polyquery::fold-constants
                (polyquery::make-b-op :int64 :+ (list (polyquery::make-b-literal :int64 1)
                                                      (polyquery::make-b-literal :int64 2))))))
  "TIMEOUT")

;;; Expression utilities used on long chains

(deftest limits.split-conjuncts-order
    (let* ((cs (loop for i below 5 collect (polyquery::make-b-literal :int64 i)))
           (tree (polyquery::conjoin cs)))
      (equal (polyquery::split-conjuncts tree) cs))
  t)

(deftest limits.bexpr-index
    (let* ((a (polyquery::make-b-column :int64 0 "a"))
           (b (polyquery::make-b-column :int64 1 "b"))
           (a2 (polyquery::make-b-column :int64 0 "a"))
           (index (polyquery::make-bexpr-index (list a b a2))))
      (list (polyquery::bexpr-index-position index a2)
            (polyquery::bexpr-index-position index b)
            (polyquery::bexpr-index-add index (polyquery::make-b-literal :int64 7))
            (polyquery::bexpr-index-add index (polyquery::make-b-literal :int64 7))
            (polyquery::bexpr-index-count index)))
  (0 1 3 3 4))

(deftest limits.cached-properties
    (let* ((col (polyquery::make-b-column :int64 2 "c"))
           (sum (polyquery::make-b-op :int64 :+ (list col (polyquery::make-b-literal :int64 1))))
           (lit (polyquery::make-b-op :int64 :+ (list (polyquery::make-b-literal :int64 1)
                                                      (polyquery::make-b-literal :int64 1)))))
      (list (polyquery::bexpr-constant-p sum) (polyquery::bexpr-constant-p lit)
            (polyquery::may-fail-p sum) (polyquery::bexpr-column-indexes sum)
            (polyquery::bexpr-describe sum)))
  (nil t t (2) "(c + 1)"))

;;; Stack exhaustion is RESOURCE_LIMIT, in any thread

(defun recurse-forever (n)
  (declare (notinline recurse-forever))
  (1+ (recurse-forever (1+ n))))

(defun error-response-code (response)
  (values (polyquery::json-get (polyquery::json-get response "error") "code")))

(deftest limits.stack-exhaustion
    (error-response-code (polyquery::call-with-error-response 1 (lambda () (recurse-forever 0))))
  "RESOURCE_LIMIT")

(deftest limits.stack-exhaustion-in-worker-thread
    (error-response-code
     (polyquery::call-with-error-response
      1 (lambda ()
          (polyquery::run-in-threads (list (lambda () 1) (lambda () (recurse-forever 0)))))))
  "RESOURCE_LIMIT")
