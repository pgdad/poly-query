(ns polyquery.server.admission
  "Admission control (spec/concurrency/concurrency.md §2): at most `workers`
  queries execute at once, up to `queue-depth` further queries wait in FIFO
  order for a worker, anything beyond that is rejected immediately."
  (:import (java.util ArrayDeque)))

(set! *warn-on-reflection* true)

(defrecord Admission [^long workers ^long queue-depth ^ArrayDeque waiting running])

(defn make-admission [workers queue-depth]
  (->Admission (max 1 (long workers)) (max 0 (long queue-depth)) (ArrayDeque.) (long-array 1)))

(defn try-admit!
  "Returns :running when a worker was granted, a ticket (to wait on with
  await-ticket) when the query was queued, or nil when the server is full."
  [{:keys [^ArrayDeque waiting ^longs running] :as adm}]
  (locking adm
    (cond
      (and (.isEmpty waiting) (< (aget running 0) (long (:workers adm))))
      (do (aset running 0 (inc (aget running 0))) :running)

      (< (.size waiting) (long (:queue-depth adm)))
      (let [ticket (promise)]
        (.addLast waiting ticket)
        ticket)

      :else nil)))

(defn await-ticket
  "Waits up to ms milliseconds for a queued ticket; true once it holds a
  worker."
  [ticket ^long ms]
  (true? (deref ticket ms false)))

(defn- release-locked! [{:keys [^ArrayDeque waiting ^longs running]}]
  (if-let [next-ticket (.pollFirst waiting)]
    (deliver next-ticket true)                     ; hand the worker over
    (aset running 0 (dec (aget running 0)))))

(defn release!
  "Returns a worker; the oldest queued query (if any) receives it."
  [adm]
  (locking adm (release-locked! adm)))

(defn abandon!
  "Withdraws a queued ticket (timeout, cancellation). If the worker was
  granted concurrently it is released again."
  [{:keys [^ArrayDeque waiting] :as adm} ticket]
  (locking adm
    (when-not (.removeFirstOccurrence waiting ticket)
      (release-locked! adm))))

(defn running-count ^long [{:keys [^longs running] :as adm}]
  (locking adm (aget running 0)))

(defn queued-count ^long [{:keys [^ArrayDeque waiting] :as adm}]
  (locking adm (.size waiting)))
