(ns pqledger.errors
  "Application errors (spec/apps/pqledger.md §10): every failure is an
  ex-info carrying its kind, which determines the exit status.")

(def exit-codes
  {:usage 1
   :config 2
   :import 4
   :query 5
   :ledger 6
   :other 7})

(defn fail!
  "Throws an application error of `kind` (a key of exit-codes)."
  [kind message]
  {:pre [(contains? exit-codes kind)]}
  (throw (ex-info message {::kind kind})))

(defn usage! [message] (fail! :usage message))
(defn config! [message] (fail! :config message))
(defn ledger! [message] (fail! :ledger message))

(defn kind
  "The kind of an application error, or nil for other throwables."
  [e]
  (::kind (ex-data e)))

(defn exit-code
  "The exit status of a throwable (7 for anything unexpected)."
  ^long [e]
  (exit-codes (kind e) 7))
