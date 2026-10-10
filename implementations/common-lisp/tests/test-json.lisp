;;;; test-json.lisp — JSON reader and writer.

(in-package #:polyquery-tests)

(defun roundtrip (text) (json-to-string (parse-json text)))

(deftest json.roundtrip.1 (roundtrip "{\"a\": [1, 2.50, \"x\"], \"b\": null}") "{\"a\":[1,2.50,\"x\"],\"b\":null}")
(deftest json.roundtrip.2 (roundtrip "[true,false,{}]") "[true,false,{}]")
(deftest json.unicode (values (parse-json "\"caf\\u00e9 \\ud83d\\ude00\""))
  #.(coerce (list #\c #\a #\f (code-char #xE9) #\Space (code-char #x1F600)) 'string))
(deftest json.escape (json-to-string (format nil "a\"b\\c~Cd" (code-char 9))) "\"a\\\"b\\\\c\\td\"")
(deftest json.control (json-to-string (string (code-char 1))) "\"\\u0001\"")

(defun json-fails-p (text &rest args)
  (handler-case (progn (apply #'parse-json text args) nil)
    (polyquery::json-syntax-error () t)))

(deftest json.invalid.1 (json-fails-p "{\"a\": 1,}") t)
(deftest json.invalid.2 (json-fails-p "[NaN]") t)
(deftest json.invalid.3 (json-fails-p "01") t)
(deftest json.invalid.4 (json-fails-p "{\"a\":1} x") t)
(deftest json.invalid.5 (json-fails-p "{\"a\":1,\"a\":2}" :duplicate-keys :error) t)
(deftest json.invalid.6 (json-fails-p "\"\\ud800\"") t)
