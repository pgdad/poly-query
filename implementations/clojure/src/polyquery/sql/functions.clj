(ns polyquery.sql.functions
  "Scalar function registry (spec/sql/functions.md §1): name resolution,
  arity and type checking, result typing and constant-argument validation of
  scalar function calls. Evaluation lives in polyquery.exec.functions."
  (:require [polyquery.errors :as err]
            [polyquery.sql.bound :as b]
            [polyquery.types :as t]
            [polyquery.util.text :as text]))

(set! *warn-on-reflection* true)

(def ^:private signatures
  "Canonical name → [min-args max-args (nil = unbounded)]."
  {"ABS" [1 1] "ROUND" [1 2] "FLOOR" [1 1] "CEIL" [1 1] "SQRT" [1 1] "POWER" [2 2]
   "MOD" [2 2] "LENGTH" [1 1] "UPPER" [1 1] "LOWER" [1 1] "SUBSTR" [2 3] "TRIM" [1 1]
   "LTRIM" [1 1] "RTRIM" [1 1] "REPLACE" [3 3] "CONCAT" [1 nil] "COALESCE" [1 nil]
   "NULLIF" [2 2] "YEAR" [1 1] "MONTH" [1 1] "DAY" [1 1] "HOUR" [1 1] "MINUTE" [1 1]
   "SECOND" [1 1] "DATE_TRUNC" [2 2] "DATE_DIFF" [3 3] "PQ_SLEEP" [1 1]})

(def ^:private aliases {"CEILING" "CEIL" "SUBSTRING" "SUBSTR"})

(def date-trunc-units #{"year" "month" "day" "hour" "minute"})
(def date-diff-units #{"day"})

(defn- pos-details [e]
  (when-let [p (:pos e)] {"line" (:line p) "column" (:col p)}))

(defn- semantic! [msg e] (err/fail! "SEMANTIC_ERROR" msg (pos-details e)))
(defn- type-error! [msg e] (err/fail! "TYPE_ERROR" msg (pos-details e)))

(defn- check-type!
  "Each arg must be NULL-typed or satisfy pred."
  [fname args pred expected e]
  (doseq [a args]
    (when-not (or (= :null (:type a)) (pred (:type a)))
      (type-error! (str fname " expects " expected ", got " (t/describe (:type a))) e))))

(defn- int64? [t] (= t :int64))
(defn- string-type? [t] (= t :string))
(defn- timestamp? [t] (= t :timestamp))

(defn common-type!
  "Common type of the given expressions (CASE/COALESCE rules), or TYPE_ERROR."
  [what exprs e]
  (reduce (fn [acc x]
            (or (t/common-type acc (:type x))
                (type-error! (str what ": incompatible types " (t/describe acc) " and "
                                  (t/describe (:type x))) e)))
          :null exprs))

(defn- constant-arg
  "Evaluates a constant argument via `eval-constant`, or SEMANTIC_ERROR."
  [fname arg e eval-constant]
  (when-not (b/constant? arg)
    (semantic! (str "argument of " fname " must be a constant") e))
  (eval-constant arg))

(defn- unit-arg
  [fname arg units e eval-constant]
  (check-type! fname [arg] string-type? "a STRING unit" e)
  (let [u (constant-arg fname arg e eval-constant)]
    (when (some? u)
      (let [u (text/ascii-lower u)]
        (when-not (units u)
          (err/fail! "INVALID_ARGUMENT" (str "unknown unit '" u "' for " fname) (pos-details e)))
        u))))

(defn- call [fname type args & {:as extra}]
  (merge {:node :call :fn fname :type type :args (vec args)} extra))

(defn- same-numeric-type [fname x e]
  (check-type! fname [x] t/numeric? "a numeric argument" e)
  (:type x))

(defn- bind-round [[x n] e eval-constant]
  (let [xt (same-numeric-type "ROUND" x e)
        digits (when n
                 (check-type! "ROUND" [n] int64? "an INT64 digit count" e)
                 (constant-arg "ROUND" n e eval-constant))
        null-digits? (and n (nil? digits))
        d (long (or digits 0))
        type (case (t/kind xt)
               :decimal (t/decimal (t/result-precision xt) (max 0 (min d (t/scale xt))))
               xt)]
    (call "ROUND" type [x] :digits d :null-digits? (boolean null-digits?))))

(defn- bind-typed
  "Functions with fixed argument/result typing."
  [u args e eval-constant]
  (let [[x y] args]
    (case u
      "ABS" (call u (same-numeric-type u x e) args)
      "ROUND" (bind-round args e eval-constant)
      ("FLOOR" "CEIL") (let [xt (same-numeric-type u x e)]
                         (call u (if (t/decimal-type? xt) (t/decimal (t/result-precision xt) 0) xt) args))
      "SQRT" (do (check-type! u args t/numeric? "a numeric argument" e) (call u :float64 args))
      "POWER" (do (check-type! u args t/numeric? "numeric arguments" e) (call u :float64 args))
      "MOD" (do (check-type! u args int64? "INT64 arguments" e) (call u :int64 args))
      "LENGTH" (do (check-type! u args string-type? "a STRING" e) (call u :int64 args))
      ("UPPER" "LOWER" "TRIM" "LTRIM" "RTRIM" "REPLACE")
      (do (check-type! u args string-type? "STRING arguments" e) (call u :string args))
      "SUBSTR" (do (check-type! u [x] string-type? "a STRING" e)
                   (check-type! u (rest args) int64? "INT64 positions" e)
                   (call u :string args))
      "CONCAT" (do (check-type! u args #(not= :float64 (t/kind %)) "non-FLOAT64 arguments" e)
                   (call u :string args))
      "COALESCE" (let [ct (common-type! u args e)]
                   (call u ct (mapv #(b/coerce % ct) args)))
      "NULLIF" (do (when-not (t/comparable? (:type x) (:type y))
                     (type-error! (str "NULLIF arguments are not comparable: " (t/describe (:type x))
                                       " and " (t/describe (:type y))) e))
                   (call u (:type x) args :cmp-type (t/comparison-type (:type x) (:type y))))
      ("YEAR" "MONTH" "DAY")
      (do (check-type! u args t/temporal? "a DATE or TIMESTAMP" e) (call u :int64 args))
      ("HOUR" "MINUTE" "SECOND")
      (do (check-type! u args timestamp? "a TIMESTAMP" e) (call u :int64 args))
      "DATE_TRUNC" (let [unit (unit-arg u x date-trunc-units e eval-constant)]
                     (check-type! u [y] t/temporal? "a DATE or TIMESTAMP" e)
                     (call u :timestamp [y] :unit unit))
      "DATE_DIFF" (let [unit (unit-arg u x date-diff-units e eval-constant)]
                    (check-type! u (rest args) t/temporal? "DATE or TIMESTAMP arguments" e)
                    (call u :int64 (rest args) :unit unit))
      "PQ_SLEEP" (do (check-type! u args int64? "an INT64" e) (call u :int64 args)))))

(defn bind-call
  "Binds a scalar function call with already-bound args. `e` is the AST node
  (for positions and the DISTINCT/* flags). opts: :test-functions? and
  :eval-constant (fn evaluating a constant bound expression)."
  [fname args e {:keys [test-functions? eval-constant]}]
  (let [u (text/ascii-upper fname)
        u (get aliases u u)
        [lo hi] (get signatures u)]
    (when (or (nil? lo) (and (= u "PQ_SLEEP") (not test-functions?)))
      (semantic! (str "unknown function '" fname "'") e))
    (when (or (:star? e) (:distinct? e))
      (semantic! (str "invalid use of " (if (:star? e) "*" "DISTINCT") " in " u) e))
    (when (or (< (count args) lo) (and hi (> (count args) hi)))
      (semantic! (str u " expects " (if (= lo hi) lo (str lo ".." (or hi "n"))) " argument(s), got "
                      (count args)) e))
    (bind-typed u args e eval-constant)))
