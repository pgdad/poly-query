(ns pqledger.config
  "The configuration file (spec/apps/pqledger.md §3): locating it, parsing
  and validating its sections, and the effective import settings of an
  account."
  (:require [clojure.string :as str]
            [pqledger.errors :as errors]
            [pqledger.ini :as ini]
            [pqledger.text :as text])
  (:import (java.io File)
           (java.nio.file Files)))

(set! *warn-on-reflection* true)

(def account-name-re #"[a-z0-9_-]{1,32}")

(defn account-name? [s] (boolean (and (string? s) (re-matches account-name-re s))))

(defn category-name?
  [s]
  (boolean (and (string? s) (re-matches #"[a-z0-9_-]{1,32}" s) (not= s "uncategorized"))))

;; ---------------------------------------------------------------------------
;; Values

(defn- invalid! [where k msg]
  (errors/config! (str where ": invalid value for '" k "': " msg)))

(defn- boolean-value [v]
  (case v "true" true "false" false ::invalid))

(defn- int-value
  "v as a long when it is a decimal integer >= min, else ::invalid."
  [v ^long min]
  (if (and (re-matches #"[0-9]{1,18}" v) (>= (Long/parseLong v) min))
    (Long/parseLong v)
    ::invalid))

(defn- column-ref
  "A column reference: a 1-based position (Long) or a header name (String)."
  [v]
  (cond
    (= "" v) ::invalid
    (re-matches #"[0-9]+" v) (if (and (<= (count (str/replace v #"^0+" "")) 9)
                                      (pos? (Long/parseLong v)))
                               (Long/parseLong v)
                               ::invalid)
    :else v))

(def ^:private date-formats #{"YYYY-MM-DD" "YYYYMMDD" "MM/DD/YYYY" "DD/MM/YYYY" "DD.MM.YYYY"})

(def ^:private import-keys
  "Key → [setting, parser (value → parsed value or ::invalid), expectation]."
  {"delimiter" [:delimiter #(cond
                              (= % "tab") \tab
                              (and (= 1 (count %)) (< (int (first %)) 128)
                                   (not (#{\" \return \newline} (first %)))) (first %)
                              :else ::invalid)
                "one ASCII character or 'tab'"]
   "header" [:header boolean-value "true or false"]
   "skip_lines" [:skip-lines #(int-value % 0) "an integer >= 0"]
   "date_column" [:date-column column-ref "a column position or name"]
   "date_format" [:date-format #(if (date-formats %) % ::invalid)
                  "YYYY-MM-DD, YYYYMMDD, MM/DD/YYYY, DD/MM/YYYY or DD.MM.YYYY"]
   "description_column" [:description-column column-ref "a column position or name"]
   "amount_mode" [:amount-mode #(case % "signed" :signed "debit_credit" :debit-credit ::invalid)
                  "signed or debit_credit"]
   "amount_column" [:amount-column column-ref "a column position or name"]
   "debit_column" [:debit-column column-ref "a column position or name"]
   "credit_column" [:credit-column column-ref "a column position or name"]
   "decimal_separator" [:decimal-separator #(case % "." \. "," \, ::invalid) ". or ,"]
   "thousands_separator" [:thousands-separator
                          #(case % "none" nil "," \, "." \. "space" \space "'" \' ::invalid)
                          "none, ',', '.', space or '"]
   "currency_symbol" [:currency-symbol identity "text"]
   "invert_sign" [:invert-sign boolean-value "true or false"]})

(def import-defaults
  {:delimiter \,
   :header true
   :skip-lines 0
   :date-column "Date"
   :date-format "YYYY-MM-DD"
   :description-column "Description"
   :amount-mode :signed
   :amount-column "Amount"
   :debit-column "Debit"
   :credit-column "Credit"
   :decimal-separator \.
   :thousands-separator nil
   :currency-symbol ""
   :invert-sign false})

(defn- path-value [v] (if (= "" v) ::invalid v))

(def ^:private section-keys
  {:ledger {"data_dir" [:data-dir path-value "a path"]
            "rules_file" [:rules-file path-value "a path"]
            "budget_file" [:budget-file path-value "a path"]}
   :import import-keys
   :account import-keys
   :output {"format" [:format #(if (#{"table" "csv" "json"} %) % ::invalid) "table, csv or json"]}
   :engine {"threads" [:threads #(int-value % 1) "an integer >= 1"]
            "memory_mb" [:memory-mb #(int-value % 1) "an integer >= 1"]}})

(defn- section-id
  "[kind account-name] of a section header name, or nil if unknown."
  [^String nm]
  (cond
    (#{"ledger" "import" "output" "engine"} nm) [(keyword nm) nil]
    (str/starts-with? nm "account ") (let [a (subs nm 8)]
                                       (when (account-name? a) [:account a]))
    :else nil))

;; ---------------------------------------------------------------------------
;; Parsing

(defn- parse-sections
  "Parses configuration text into {[kind account] {setting value}}."
  [content file-name]
  (loop [entries (ini/parse content file-name)
         current nil
         sections {}
         seen-keys #{}]
    (if-let [{:keys [kind where] :as e} (first entries)]
      (case kind
        :section
        (let [id (or (section-id (:name e))
                     (errors/config! (str where ": unknown section [" (:name e) "]")))]
          (when (contains? sections id)
            (errors/config! (str where ": section [" (:name e) "] repeated")))
          (recur (rest entries) id (assoc sections id {}) #{}))
        :assign
        (let [{k :key v :value} e]
          (when-not current
            (errors/config! (str where ": assignment before the first section header")))
          (let [[setting parse expected] (or (get-in section-keys [(first current) k])
                                             (errors/config! (str where ": unknown key '" k "'")))
                parsed (parse v)]
            (when (contains? seen-keys k)
              (errors/config! (str where ": key '" k "' repeated")))
            (when (= ::invalid parsed)
              (invalid! where k (str "expected " expected)))
            (recur (rest entries) current (assoc-in sections [current setting] parsed)
                   (conj seen-keys k)))))
      sections)))

(defn- check-import-settings!
  "Validates one effective set of import settings (`what` names it)."
  [settings what]
  (when (and (:thousands-separator settings)
             (= (:thousands-separator settings) (:decimal-separator settings)))
    (errors/config! (str what ": decimal_separator and thousands_separator must differ")))
  (when-not (:header settings)
    (let [refs (cond-> [:date-column :description-column]
                 (= :signed (:amount-mode settings)) (conj :amount-column)
                 (= :debit-credit (:amount-mode settings)) (conj :debit-column :credit-column))]
      (doseq [r refs]
        (when (string? (get settings r))
          (errors/config! (str what ": " (str/replace (name r) "-" "_") " '" (get settings r)
                               "' is a column name, which requires header = true")))))))

(defn- resolve-file
  "path resolved against directory dir (absolute paths unchanged)."
  ^File [^File dir ^String path]
  (let [f (File. path)]
    (if (.isAbsolute f) f (File. dir path))))

(defn parse-config
  "Parses and validates configuration text; relative paths are resolved
  against `dir`. Returns the configuration map:
    :data-dir :rules-file :budget-file (Files; the latter two may be nil)
    :import (the [import] settings) :accounts {name settings}
    :format :threads :memory-mb"
  [content file-name ^File dir]
  (let [sections (parse-sections content file-name)
        ledger (or (get sections [:ledger nil])
                   (errors/config! (str file-name ": missing [ledger] section")))
        _ (when-not (:data-dir ledger)
            (errors/config! (str file-name ": [ledger] data_dir is required")))
        import (merge import-defaults (get sections [:import nil]))
        accounts (into {}
                       (for [[[kind a] settings] sections :when (= kind :account)]
                         [a (merge import settings)]))]
    (check-import-settings! import (str file-name ": [import]"))
    (doseq [[a settings] (sort-by key accounts)]
      (check-import-settings! settings (str file-name ": [account " a "]")))
    {:data-dir (resolve-file dir (:data-dir ledger))
     :rules-file (some->> (:rules-file ledger) (resolve-file dir))
     :budget-file (some->> (:budget-file ledger) (resolve-file dir))
     :import import
     :accounts accounts
     :format (get-in sections [[:output nil] :format] "table")
     :threads (get-in sections [[:engine nil] :threads])
     :memory-mb (get-in sections [[:engine nil] :memory-mb])}))

(defn import-settings
  "The effective import settings of an account."
  [config account]
  (get-in config [:accounts account] (:import config)))

;; ---------------------------------------------------------------------------
;; Locating and reading

(defn locate
  "The configuration file to use (§3.1): --config, else $PQLEDGER_CONFIG if
  set and non-empty, else pqledger.conf in the current directory."
  ^File [config-option env-value]
  (let [^String path (cond
                       config-option config-option
                       (and env-value (not= "" env-value)) env-value
                       :else "pqledger.conf")]
    (.getAbsoluteFile (File. path))))

(defn read-text-file
  "The text of a UTF-8 file, or a configuration error naming `what`."
  ^String [^File f what]
  (let [bs (try
             (when-not (.isFile f) (throw (java.io.IOException. "not a file")))
             (Files/readAllBytes (.toPath f))
             (catch java.io.IOException _
               (errors/config! (str "cannot read " what " " (.getPath f)))))]
    (or (text/decode-utf8 bs)
        (errors/config! (str what " " (.getPath f) " is not valid UTF-8")))))

(defn load-config
  "Reads and validates the configuration file f."
  [^File f]
  (parse-config (read-text-file f "configuration file") (.getName f) (.getParentFile f)))
