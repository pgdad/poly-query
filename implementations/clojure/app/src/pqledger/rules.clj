(ns pqledger.rules
  "The category rules file and the budget file (spec/apps/pqledger.md §5)."
  (:require [clojure.string :as str]
            [pqledger.config :as config]
            [pqledger.errors :as errors]
            [pqledger.ini :as ini]
            [pqledger.text :as text]))

(set! *warn-on-reflection* true)

(defn- assignments
  "The KEY = VALUE entries of a sectionless file; category keys validated."
  [content file-name]
  (for [{:keys [kind where] :as e} (ini/parse content file-name)]
    (do
      (when (= kind :section)
        (errors/config! (str where ": sections are not allowed in this file")))
      (when-not (config/category-name? (:key e))
        (errors/config! (str where ": invalid category name '" (:key e) "'")))
      e)))

(defn parse-rules
  "Parses a rules file into [{:rule-no n :category c :pattern P} …] in file
  order (patterns upper-cased, as written otherwise)."
  [content file-name]
  (->> (assignments content file-name)
       (mapcat (fn [{:keys [key value where]}]
                 (for [p (str/split value #"," -1)
                       :let [p (text/trim p)]]
                   (do
                     (when (= "" p)
                       (errors/config! (str where ": empty pattern")))
                     (when (re-find #"[%_]" p)
                       (errors/config! (str where ": pattern '" p "' contains % or _")))
                     {:category key :pattern (text/ascii-upper p)}))))
       (map-indexed (fn [i r] (assoc r :rule-no (inc i))))
       vec))

(defn parse-budgets
  "Parses a budget file into [{:category c :amount BigDecimal} …] in file
  order."
  [content file-name]
  (loop [entries (assignments content file-name) seen #{} out []]
    (if-let [{:keys [key value where]} (first entries)]
      (do
        (when (contains? seen key)
          (errors/config! (str where ": category '" key "' listed twice")))
        (when-not (re-matches #"[0-9]{1,16}(\.[0-9]{1,2})?" value)
          (errors/config! (str where ": invalid budget amount '" value "'")))
        (recur (rest entries) (conj seen key)
               (conj out {:category key :amount (.setScale (BigDecimal. ^String value) 2)})))
      out)))

(defn read-rules
  "The rules of the configured rules file (none when not configured)."
  [{:keys [rules-file]}]
  (if rules-file
    (parse-rules (config/read-text-file rules-file "rules file") (.getName ^java.io.File rules-file))
    []))

(defn read-budgets
  "The budgets of the configured budget file, or nil when none is configured."
  [{:keys [budget-file]}]
  (when budget-file
    (parse-budgets (config/read-text-file budget-file "budget file") (.getName ^java.io.File budget-file))))
