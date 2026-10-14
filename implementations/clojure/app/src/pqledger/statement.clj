(ns pqledger.statement
  "Reading bank-statement CSV exports (spec/apps/pqledger.md §6.2-§6.3):
  the CSV records with their physical line numbers, and their conversion
  into transactions (date, description, merchant, amount) with an account's
  import settings."
  (:require [clojure.string :as str]
            [pqledger.errors :as errors]
            [pqledger.text :as text])
  (:import (java.time LocalDate)
           (java.util ArrayList)))

(set! *warn-on-reflection* true)

(defn- data-error!
  "Throws an import data error; line may be nil (an error of the file)."
  [file-name line msg]
  (errors/fail! :import (str file-name (when line (str ":" line)) ": " msg)))

;; ---------------------------------------------------------------------------
;; CSV records

(defn- skip-lines
  "[index line-number] after the first k physical lines of s."
  [^String s ^long k]
  (loop [i 0 skipped 0]
    (if (or (= skipped k) (>= i (.length s)))
      [i (inc skipped)]
      (let [nl (.indexOf s "\n" (int i))]
        (if (neg? nl)
          [(.length s) (inc (inc skipped))]
          (recur (inc nl) (inc skipped)))))))

(defn- line-end
  "Length of the line terminator at i (1 for \\n, 2 for \\r\\n), or 0."
  ^long [^String s ^long i]
  (let [n (.length s)]
    (cond
      (>= i n) 0
      (= \newline (.charAt s i)) 1
      (and (= \return (.charAt s i)) (< (inc i) n) (= \newline (.charAt s (inc i)))) 2
      :else 0)))

(defn- read-field!
  "Reads one field starting at pos[0] into sb (pos[1]: the current physical
  line, advanced over line breaks inside quotes). Returns :field when a
  delimiter follows, :record at a record terminator or the end of input."
  [^String s delim ^longs pos ^StringBuilder sb file-name rec-line]
  (let [n (.length s)
        delim (long delim)]
    (if (and (< (aget pos 0) n) (= \" (.charAt s (aget pos 0))))
      ;; quoted field
      (do
        (aset pos 0 (inc (aget pos 0)))
        (loop []
          (let [i (aget pos 0)]
            (cond
              (>= i n) (data-error! file-name rec-line "unterminated quoted field")
              (= \" (.charAt s i))
              (if (and (< (inc i) n) (= \" (.charAt s (inc i))))
                (do (.append sb \") (aset pos 0 (+ i 2)) (recur))
                (aset pos 0 (inc i)))
              :else
              (let [c (.charAt s i)]
                (.append sb c)
                (when (= c \newline) (aset pos 1 (inc (aget pos 1))))
                (aset pos 0 (inc i))
                (recur)))))
        (let [i (aget pos 0)]
          (cond
            (>= i n) :record
            (= delim (long (int (.charAt s i)))) (do (aset pos 0 (inc i)) :field)
            (pos? (line-end s i)) (do (aset pos 0 (+ i (line-end s i))) (aset pos 1 (inc (aget pos 1))) :record)
            :else (data-error! file-name rec-line "unexpected character after a closing quote"))))
      ;; unquoted field
      (loop []
        (let [i (aget pos 0)]
          (cond
            (>= i n) :record
            (= delim (long (int (.charAt s i)))) (do (aset pos 0 (inc i)) :field)
            (pos? (line-end s i)) (do (aset pos 0 (+ i (line-end s i))) (aset pos 1 (inc (aget pos 1))) :record)
            :else (do (.append sb (.charAt s i)) (aset pos 0 (inc i)) (recur))))))))

(defn parse-csv
  "Parses CSV text (RFC 4180: quote \", the delimiter, \\n or \\r\\n record
  terminators, empty lines ignored) into [{:line n :fields [..]} …], :line
  being the physical line on which the record starts. The first skip
  physical lines are skipped. Errors name file-name."
  [^String s delim ^long skip file-name]
  (let [delim (long (int (char delim)))
        n (.length s)
        [start first-line] (skip-lines s skip)
        pos (long-array [start first-line])
        sb (StringBuilder.)
        records (ArrayList.)]
    (loop []
      (let [i (aget pos 0)]
        (cond
          (>= i n) nil
          ;; an empty line
          (pos? (line-end s i))
          (do (aset pos 0 (+ i (line-end s i))) (aset pos 1 (inc (aget pos 1))) (recur))
          :else
          (let [rec-line (aget pos 1)
                fields (ArrayList.)]
            (loop []
              (let [end (read-field! s delim pos sb file-name rec-line)]
                (.add fields (.toString sb))
                (.setLength sb 0)
                (when (= end :field) (recur))))
            (.add records {:line rec-line :fields (vec fields)})
            (recur)))))
    (vec records)))

;; ---------------------------------------------------------------------------
;; Field conversion

(defn- days-in-month ^long [^long y ^long m]
  (case (int m)
    2 (if (and (zero? (rem y 4)) (or (pos? (rem y 100)) (zero? (rem y 400)))) 29 28)
    (4 6 9 11) 30
    31))

(def ^:private date-patterns
  "date_format → [regex, group indexes of year, month, day]."
  {"YYYY-MM-DD" [#"([0-9]{4})-([0-9]{2})-([0-9]{2})" 1 2 3]
   "YYYYMMDD" [#"([0-9]{4})([0-9]{2})([0-9]{2})" 1 2 3]
   "MM/DD/YYYY" [#"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})" 3 1 2]
   "DD/MM/YYYY" [#"([0-9]{1,2})/([0-9]{1,2})/([0-9]{4})" 3 2 1]
   "DD.MM.YYYY" [#"([0-9]{1,2})\.([0-9]{1,2})\.([0-9]{4})" 3 2 1]})

(defn parse-date
  "The LocalDate of a date field in date_format fmt, or nil if invalid."
  [^String field fmt]
  (let [[re yi mi di] (date-patterns fmt)]
    (when-let [m (re-matches re (text/trim field))]
      (let [y (Long/parseLong (nth m yi))
            mo (Long/parseLong (nth m mi))
            d (Long/parseLong (nth m di))]
        (when (and (<= 1 y 9999) (<= 1 mo 12) (<= 1 d (days-in-month y mo)))
          (LocalDate/of (int y) (int mo) (int d)))))))

(def ^:private max-cents
  "Largest |amount| of a DECIMAL(18,2), in cents."
  999999999999999999)

(defn parse-amount
  "Converts an amount field (§6.2 step 3) into cents (a long), or returns a
  string describing why it is invalid."
  [^String field {:keys [currency-symbol thousands-separator decimal-separator]}]
  (let [t (text/trim field)
        [negative? t] (cond
                        (and (str/starts-with? t "(") (str/ends-with? t ")") (>= (count t) 2))
                        [true (subs t 1 (dec (count t)))]
                        (str/starts-with? t "-") [true (subs t 1)]
                        (str/starts-with? t "+") [false (subs t 1)]
                        :else [false t])
        cur ^String currency-symbol
        t (text/trim (cond
                       (= "" cur) t
                       (str/starts-with? t cur) (subs t (count cur))
                       (str/ends-with? t cur) (subs t 0 (- (count t) (count cur)))
                       :else t))
        t (if thousands-separator (str/replace t (str thousands-separator) "") t)
        t (if (= \, decimal-separator) (str/replace t "," ".") t)]
    (if-let [[_ int-part frac] (re-matches #"([0-9]{1,16})(?:\.([0-9]{1,2}))?" t)]
      (let [cents (+ (* 100 (Long/parseLong int-part))
                     (case (count frac) 0 0 1 (* 10 (Long/parseLong frac)) 2 (Long/parseLong frac)))]
        (if negative? (- cents) cents))
      (str "invalid amount '" (text/trim field) "'"))))

;; ---------------------------------------------------------------------------
;; Merchant normalization (§6.3)

(defn normalize-merchant
  ^String [^String description]
  (let [m (-> (text/ascii-upper description)
              (str/replace #"[ \t]+" " ")
              (text/trim))
        i (str/last-index-of m " ")]
    (if (and i (re-matches #"#[0-9]+|[0-9]{3,}" (subs m (inc i))))
      (subs m 0 i)
      m)))

;; ---------------------------------------------------------------------------
;; Records → transactions

(defn- column-index
  "The 0-based index of a column reference (position or header name)."
  [ref header ^long ncols file-name]
  (if (integer? ref)
    (if (<= ref ncols)
      (dec ref)
      (data-error! file-name nil (str "column " ref " does not exist (the file has " ncols " columns)")))
    (let [k (text/ascii-lower ref)]
      (or (first (keep-indexed (fn [i h] (when (= k (text/ascii-lower (text/trim h))) i)) header))
          (data-error! file-name nil (str "the header has no column '" ref "'"))))))

(defn- convert-record
  "The transaction of one data record, or throws an import data error."
  [{:keys [line fields]} {:keys [date-format amount-mode invert-sign] :as settings} cols ncols file-name]
  (let [field #(nth fields (get cols %))
        fail #(data-error! file-name line %)
        _ (when-not (= ncols (count fields))
            (fail (str "record has " (count fields) " fields, expected " ncols)))
        date (or (parse-date (field :date) date-format)
                 (fail (str "invalid date '" (text/trim (field :date)) "' (expected " date-format ")")))
        amount (fn [k]
                 (let [a (parse-amount (field k) settings)]
                   (if (string? a) (fail a) a)))
        cents (if (= :signed amount-mode)
                (amount :amount)
                (let [debit-empty? (= "" (text/trim (field :debit)))
                      credit-empty? (= "" (text/trim (field :credit)))]
                  (when (and debit-empty? credit-empty?)
                    (fail "both debit and credit are empty"))
                  (- (if credit-empty? 0 (long (amount :credit)))
                     (if debit-empty? 0 (long (amount :debit))))))
        cents (long (if invert-sign (- (long cents)) cents))
        description (text/trim (field :description))]
    (when (> (Math/abs cents) (long max-cents))
      (fail "amount out of range"))
    {:line line
     :date date
     :description description
     :merchant (normalize-merchant description)
     :cents cents}))

(defn transactions
  "Converts the text of a statement file into transactions
  [{:line :date :description :merchant :cents} …] using an account's
  effective import settings. Any invalid record ⇒ import data error."
  [^String content settings file-name]
  (let [records (parse-csv content (:delimiter settings) (:skip-lines settings) file-name)
        header? (:header settings)
        _ (when (and header? (empty? records))
            (data-error! file-name nil "missing header record"))
        header (when header? (:fields (first records)))
        data (if header? (rest records) records)
        ncols (count (:fields (first records)))
        refs (cond-> {:date (:date-column settings) :description (:description-column settings)}
               (= :signed (:amount-mode settings)) (assoc :amount (:amount-column settings))
               (= :debit-credit (:amount-mode settings)) (assoc :debit (:debit-column settings)
                                                                :credit (:credit-column settings)))
        cols (when (seq records)
               (into {} (map (fn [[k ref]] [k (column-index ref header ncols file-name)])) refs))]
    (mapv #(convert-record % settings cols ncols file-name) data)))
