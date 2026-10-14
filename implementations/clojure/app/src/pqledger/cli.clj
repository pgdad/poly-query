(ns pqledger.cli
  "Command-line parsing (spec/apps/pqledger.md §2): global options, the
  command and its options and positional arguments. Every problem is a
  usage error (exit 1)."
  (:require [clojure.string :as str]
            [pqledger.config :as config]
            [pqledger.errors :as errors])
  (:import (java.time YearMonth)))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Option values

(defn parse-month
  "A YYYY-MM month (year 0001-9999, month 01-12) as a YearMonth, or nil."
  [^String s]
  (when-let [[_ y m] (re-matches #"([0-9]{4})-([0-9]{2})" s)]
    (let [y (Long/parseLong y) m (Long/parseLong m)]
      (when (and (<= 1 y 9999) (<= 1 m 12))
        (YearMonth/of (int y) (int m))))))

(defn- month-value [opt s]
  (or (parse-month s) (errors/usage! (str opt ": invalid month '" s "' (expected YYYY-MM)"))))

(defn- account-value [opt s]
  (if (config/account-name? s)
    s
    (errors/usage! (str opt ": invalid account name '" s "' (expected [a-z0-9_-]{1,32})"))))

(defn- category-value [opt s]
  (if (or (config/category-name? s) (= s "uncategorized"))
    s
    (errors/usage! (str opt ": invalid category '" s "'"))))

(defn- positive-int-value [opt s]
  (if (and (re-matches #"[0-9]{1,18}" s) (pos? (Long/parseLong s)))
    (Long/parseLong s)
    (errors/usage! (str opt ": expected a positive integer, got '" s "'"))))

;; ---------------------------------------------------------------------------
;; Commands

(def ^:private filter-options
  {"--month" [:month month-value]
   "--from" [:from month-value]
   "--to" [:to month-value]
   "--account" [:account account-value]})

(def commands
  "Command → {:options {opt [key parser]} :flags {opt key} :positional
  [min max] :usage text}."
  {"init" {:usage "init"}
   "import" {:options {"--account" [:account account-value]}
             :positional [1 1]
             :usage "import FILE --account NAME"}
   "report monthly" {:options filter-options
                     :usage "report monthly [--month M | --from M --to M] [--account NAME]"}
   "report categories" {:options filter-options
                        :usage "report categories [--month M | --from M --to M] [--account NAME]"}
   "report merchants" {:options (assoc filter-options "--top" [:top positive-int-value])
                       :usage "report merchants [filters] [--top N]"}
   "budget" {:options {"--month" [:month month-value] "--account" [:account account-value]}
             :usage "budget --month M [--account NAME]"}
   "accounts" {:usage "accounts"}
   "list" {:options (assoc filter-options "--category" [:category category-value])
           :flags {"--uncategorized" :uncategorized}
           :usage "list [filters] [--category C | --uncategorized]"}
   "export" {:options filter-options
             :usage "export [filters]"}
   "set-category" {:flags {"--clear" :clear}
                   :positional [1 2]
                   :usage "set-category ID CATEGORY | set-category ID --clear"}
   "query" {:positional [1 1]
            :usage "query SQL"}
   "help" {:usage "help"}
   "version" {:usage "version"}})

(defn- parse-command-args
  "Parses the arguments after the command into {:opts {…} :args [...]}."
  [command args]
  (let [{:keys [options flags positional]} (commands command)
        [min-pos max-pos] (or positional [0 0])]
    (loop [args args opts {} pos []]
      (if-let [[a & more] (seq args)]
        (cond
          (contains? flags a)
          (let [k (flags a)]
            (when (contains? opts k) (errors/usage! (str "option " a " repeated")))
            (recur more (assoc opts k true) pos))

          (contains? options a)
          (let [[k parse] (options a)]
            (when (contains? opts k) (errors/usage! (str "option " a " repeated")))
            (when-not more (errors/usage! (str "option " a " requires a value")))
            (recur (rest more) (assoc opts k (parse a (first more))) pos))

          (str/starts-with? a "--")
          (errors/usage! (str "unknown option " a " for '" command "'"))

          (< (count pos) max-pos) (recur more opts (conj pos a))
          :else (errors/usage! (str "unexpected argument '" a "'")))
        (do
          (when (< (count pos) min-pos)
            (errors/usage! (str "missing arguments; usage: pqledger " (:usage (commands command)))))
          {:opts opts :args pos})))))

(defn- check-filters! [{:keys [month from to]}]
  (when (and month (or from to))
    (errors/usage! "--month cannot be combined with --from or --to"))
  (when (and from to (pos? (.compareTo ^YearMonth from ^YearMonth to)))
    (errors/usage! "--from is later than --to")))

(defn- parse-id [^String s]
  (if (and (re-matches #"[0-9]+" s) (re-find #"[1-9]" s))
    (let [b (BigInteger. s)]
      ;; ids beyond INT64 exist in no ledger (exit 6 later)
      (if (< (.bitLength b) 64) (.longValue b) Long/MAX_VALUE))
    (errors/usage! (str "invalid transaction id '" s "' (expected a positive integer)"))))

(defn- check-command!
  "Command-specific validation; returns the (possibly completed) parse."
  [{:keys [command opts args] :as parsed}]
  (check-filters! opts)
  (case command
    "import" (when-not (:account opts) (errors/usage! "import requires --account NAME"))
    "budget" (when-not (:month opts) (errors/usage! "budget requires --month M"))
    "list" (when (and (:category opts) (:uncategorized opts))
             (errors/usage! "--category and --uncategorized cannot be combined"))
    "set-category" (if (:clear opts)
                     (when-not (= 1 (count args))
                       (errors/usage! "usage: pqledger set-category ID --clear"))
                     (do (when-not (= 2 (count args))
                           (errors/usage! "usage: pqledger set-category ID CATEGORY"))
                         (when-not (config/category-name? (second args))
                           (errors/usage! (str "invalid category name '" (second args)
                                               "' (expected [a-z0-9_-]{1,32}, not 'uncategorized')")))))
    nil)
  (cond-> parsed
    (= command "set-category") (assoc :id (parse-id (first args)))))

(defn parse
  "Parses the command line into {:global {:config :format :help} :command
  name :opts {…} :args [...]}."
  [argv]
  (loop [argv argv global {}]
    (let [[a & more] argv]
      (cond
        (= a "--help") (if (:help global)
                         (errors/usage! "option --help repeated")
                         (recur more (assoc global :help true)))

        (#{"--config" "--format"} a)
        (let [k (keyword (subs a 2))]
          (when (contains? global k) (errors/usage! (str "option " a " repeated")))
          (when-not more (errors/usage! (str "option " a " requires a value")))
          (when (and (= k :format) (not (#{"table" "csv" "json"} (first more))))
            (errors/usage! (str "--format: expected table, csv or json, got '" (first more) "'")))
          (recur (rest more) (assoc global k (first more))))

        (and a (str/starts-with? a "--")) (errors/usage! (str "unknown option " a))

        (and (nil? a) (:help global)) {:global global :command "help" :opts {} :args []}
        (nil? a) (errors/usage! "missing command (try 'pqledger help')")

        :else
        (let [[command rest-args] (if (= a "report")
                                    (let [sub (first more)]
                                      (when-not (#{"monthly" "categories" "merchants"} sub)
                                        (errors/usage! "usage: pqledger report monthly|categories|merchants"))
                                      [(str "report " sub) (rest more)])
                                    [a more])]
          (when-not (commands command)
            (errors/usage! (str "unknown command '" command "' (try 'pqledger help')")))
          (let [command (if (:help global) "help" command)]
            (check-command! (merge {:global global :command command}
                                   (parse-command-args command rest-args)))))))))

(defn usage-text
  "The help text."
  ^String []
  (str "usage: pqledger [--config PATH] [--format table|csv|json] COMMAND [ARGS]\n"
       "\n"
       "Commands:\n"
       (str/join (for [c ["init" "import" "report monthly" "report categories" "report merchants"
                          "budget" "accounts" "list" "export" "set-category" "query" "help" "version"]]
                   (str "  pqledger " (:usage (commands c)) "\n")))
       "\n"
       "Filters: --month YYYY-MM, or --from YYYY-MM and/or --to YYYY-MM; --account NAME.\n"
       "The configuration is --config PATH, else $PQLEDGER_CONFIG, else ./pqledger.conf.\n"
       "Exit status: 0 ok, 1 usage, 2 configuration, 3 over budget, 4 import data,\n"
       "5 query error, 6 ledger state, 7 other error. See APP.md for details.\n"))
