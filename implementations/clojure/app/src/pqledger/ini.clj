(ns pqledger.ini
  "The line syntax of the configuration, rules and budget files
  (spec/apps/pqledger.md §3.2): blank lines, comments, section headers and
  KEY = VALUE assignments."
  (:require [clojure.string :as str]
            [pqledger.errors :as errors]
            [pqledger.text :as text]))

(set! *warn-on-reflection* true)

(defn- unquote-value
  "Removes the quotes of a quoted value (\\\" and \\\\ escapes inside;
  any other character stands for itself); other values are returned
  unchanged."
  [^String v]
  (if (and (>= (count v) 2) (str/starts-with? v "\"") (str/ends-with? v "\""))
    (let [inner (subs v 1 (dec (count v)))
          sb (StringBuilder.)]
      (loop [i 0]
        (if (< i (count inner))
          (let [c (.charAt inner i)]
            (cond
              (and (= c \\) (< (inc i) (count inner)) (#{\" \\} (.charAt inner (inc i))))
              (do (.append sb (.charAt inner (inc i))) (recur (+ i 2)))
              :else (do (.append sb c) (recur (inc i)))))
          (.toString sb))))
    v))

(defn parse-line
  "Classifies one line: nil (blank or comment), [:section NAME] or
  [:assign KEY VALUE]; throws a configuration error for anything else.
  `where` prefixes error messages (\"FILE:LINE\")."
  [^String line where]
  (let [l (text/trim line)]
    (cond
      (= "" l) nil
      (#{\# \;} (first l)) nil
      (and (str/starts-with? l "[") (str/ends-with? l "]")) [:section (subs l 1 (dec (count l)))]
      :else
      (let [i (str/index-of l "=")]
        (when-not i
          (errors/config! (str where ": expected KEY = VALUE, a [section] or a comment")))
        (let [k (text/trim (subs l 0 i))
              v (unquote-value (text/trim (subs l (inc i))))]
          (when (= "" k) (errors/config! (str where ": missing key before '='")))
          [:assign k v])))))

(defn parse
  "Parses text into [{:line n :kind :section|:assign …}] entries.
  file-name is used in error messages."
  [^String content file-name]
  (into []
        (keep-indexed
         (fn [i line]
           (let [where (str file-name ":" (inc i))]
             (when-let [[kind a b] (parse-line line where)]
               (case kind
                 :section {:line (inc i) :where where :kind :section :name a}
                 :assign {:line (inc i) :where where :kind :assign :key a :value b})))))
        (text/lines (cond-> content (str/starts-with? content "\uFEFF") (subs 1)))))
