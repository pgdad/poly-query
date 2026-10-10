(ns polyquery.util.log
  "Minimal structured logging: JSON lines on stderr, filtered by level."
  (:require [polyquery.util.json :as json])
  (:import (java.time Instant)))

(def ^:private levels {:debug 0 :info 1 :warn 2 :error 3 :off 4})

(defonce ^:private current-level (atom :info))

(defn set-level!
  "Sets the log level from a string; returns false for unknown levels."
  [^String s]
  (if-let [l (levels (keyword s))]
    (do (reset! current-level (keyword s)) (boolean l))
    false))

(defn enabled? [level]
  (>= (long (levels level)) (long (levels @current-level))))

(defn- emit [level msg fields]
  (when (enabled? level)
    (let [line (json/write-str (merge {"ts" (str (Instant/now)) "level" (name level) "msg" msg} fields))]
      (locking *err*
        (binding [*out* *err*]
          (println line))))))

(defn debug ([msg] (emit :debug msg nil)) ([msg fields] (emit :debug msg fields)))
(defn info ([msg] (emit :info msg nil)) ([msg fields] (emit :info msg fields)))
(defn warn ([msg] (emit :warn msg nil)) ([msg fields] (emit :warn msg fields)))
(defn error ([msg] (emit :error msg nil)) ([msg fields] (emit :error msg fields)))
