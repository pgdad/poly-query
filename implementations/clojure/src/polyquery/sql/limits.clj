(ns polyquery.sql.limits
  "The engine's statement size limits (CR-6, spec/changes/expression-limits.md).
  Every stage after parsing processes expressions in time linear in their
  size, recursing at most once per tree level, on threads with large stacks;
  these limits keep that recursion and the work per statement bounded. A
  statement beyond a limit fails with RESOURCE_LIMIT naming the measure."
  (:require [polyquery.errors :as err]))

(set! *warn-on-reflection* true)

(def max-text-bytes
  "SQL text length, in UTF-8 bytes (16 MiB)."
  (* 16 1024 1024))

(def max-nesting-depth
  "Expression nesting depth, counted as CR-6 §1 defines it (a chain of
  binary operators of one precedence level is one level)."
  4096)

(def max-operands
  "Literals, column references and `*` arguments in one statement."
  250000)

(defn exceeded!
  "Throws the RESOURCE_LIMIT error of a statement beyond limit `limit` of
  `measure`."
  [measure limit]
  (err/fail! "RESOURCE_LIMIT" (str measure " exceeds " limit) {"measure" measure "limit" limit}))

(defn utf8-length
  "Length of s in UTF-8 bytes."
  ^long [^String s]
  (let [n (.length s)]
    (loop [i 0 bytes 0]
      (if (= i n)
        bytes
        (let [c (int (.charAt s i))]
          (cond
            (< c 0x80) (recur (inc i) (inc bytes))
            (< c 0x800) (recur (inc i) (+ bytes 2))
            ;; a surrogate pair (4 bytes) is two chars
            (Character/isSurrogate (char c)) (recur (inc i) (+ bytes 2))
            :else (recur (inc i) (+ bytes 3))))))))

(defn check-text!
  "RESOURCE_LIMIT when the SQL text is longer than max-text-bytes."
  [^String sql]
  ;; a char is at most 3 UTF-8 bytes: count exactly only when it may matter
  (when (and (> (* 3 (.length sql)) max-text-bytes) (> (utf8-length sql) max-text-bytes))
    (exceeded! "SQL text length in bytes" max-text-bytes)))
