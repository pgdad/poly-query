(ns polyquery.sql.functions
  "Scalar function registry (spec/sql/functions.md §1): binding (arity and
  type checking) of scalar function calls. Evaluation lives in
  polyquery.exec.expr."
  (:require [polyquery.errors :as err]
            [polyquery.types :as t]
            [polyquery.util.text :as text]))

(def ^:private later-phase-functions
  "Functions of the sql.functions capability that this engine does not
  implement yet: calls are rejected with UNSUPPORTED rather than as unknown."
  #{"ABS" "ROUND" "FLOOR" "CEIL" "CEILING" "SQRT" "POWER" "MOD" "LENGTH" "UPPER" "LOWER"
    "SUBSTR" "SUBSTRING" "TRIM" "LTRIM" "RTRIM" "REPLACE" "CONCAT" "COALESCE" "NULLIF"
    "YEAR" "MONTH" "DAY" "HOUR" "MINUTE" "SECOND" "DATE_TRUNC" "DATE_DIFF"})

(defn- pos-details [e]
  (when-let [p (:pos e)] {"line" (:line p) "column" (:col p)}))

(defn- check-arity! [fname args n e]
  (when-not (= n (count args))
    (err/fail! "SEMANTIC_ERROR" (str fname " expects " n " argument(s)") (pos-details e))))

(defn- check-arg-type! [fname arg pred expected e]
  (when-not (or (= :null (:type arg)) (pred (:type arg)))
    (err/fail! "TYPE_ERROR" (str fname " expects " expected ", got " (t/describe (:type arg)))
               (pos-details e))))

(defn bind-call
  "Binds a scalar function call with already-bound args. `e` is the AST node
  (for positions and the DISTINCT/* flags)."
  [fname args e options]
  (let [u (text/ascii-upper fname)]
    (when (or (:star? e) (:distinct? e))
      (err/fail! "SEMANTIC_ERROR" (str "invalid use of " (if (:star? e) "*" "DISTINCT") " in " u)
                 (pos-details e)))
    (cond
      (and (= u "PQ_SLEEP") (:test-functions? options))
      (do (check-arity! u args 1 e)
          (check-arg-type! u (first args) #{:int64} "INT64" e)
          {:node :call :fn "PQ_SLEEP" :type :int64 :args args})

      (later-phase-functions u)
      (err/fail! "UNSUPPORTED" (str "function " u " is not supported") (pos-details e))

      :else
      (err/fail! "SEMANTIC_ERROR" (str "unknown function '" fname "'") (pos-details e)))))
