(ns polyquery.sql.lexer-test
  (:require [clojure.test :refer [deftest is]]
            [polyquery.sql.lexer :as lexer]
            [polyquery.test-util :refer [error-code]]))

(defn- toks [s] (mapv (juxt :type :text) (butlast (lexer/tokenize s))))

(deftest tokenizes
  (is (= [[:keyword "SELECT"] [:ident "a"] [:op ","] [:qident "x \"y\""] [:keyword "FROM"] [:ident "t"]]
         (toks "select a, \"x \"\"y\"\"\" FROM t")))
  (is (= [[:number "1.5"] [:number ".5"] [:number "3."] [:number "1e3"] [:number "2.5E-4"]]
         (toks "1.5 .5 3. 1e3 2.5E-4")))
  (is (= [[:string "it's"] [:op "<="] [:op "<>"] [:op "!="] [:op "||"]]
         (toks "'it''s' <= <> != ||")))
  (is (= [[:number "1"] [:number "2"]] (toks "1 -- comment\n /* block */ 2"))))

(deftest positions
  (let [[_ b] (lexer/tokenize "SELECT\n  x")]
    (is (= [2 3] [(:line b) (:col b)]))))

(deftest lexical-errors
  (is (= "PARSE_ERROR" (error-code (lexer/tokenize "SELECT 'abc"))))
  (is (= "PARSE_ERROR" (error-code (lexer/tokenize "SELECT /* x"))))
  (is (= "PARSE_ERROR" (error-code (lexer/tokenize "SELECT @"))))
  (is (= "PARSE_ERROR" (error-code (lexer/tokenize "SELECT 1abc")))))
