(ns polyquery.util.threads
  "Threads for query work. Expressions are processed recursively (one frame
  group per tree level), so every thread that parses, analyzes, plans or
  evaluates a query — including parallel workers — gets the same large
  stack (spec/changes/expression-limits.md: worker threads must be able to
  evaluate any expression the engine accepts). The stack is reserved
  address space, committed only as it is used."
  (:import (java.util.concurrent ThreadFactory)
           (java.util.concurrent.atomic AtomicLong)))

(set! *warn-on-reflection* true)

(def ^:const stack-bytes
  "Stack size of query threads."
  (* 256 1024 1024))

(defn thread
  "An unstarted platform thread running f with the query stack size."
  ^Thread [^String name ^Runnable f]
  (Thread. nil f name (long stack-bytes)))

(defn factory
  "ThreadFactory of daemon query threads named prefix-1, prefix-2, …"
  ^ThreadFactory [prefix]
  (let [n (AtomicLong.)]
    (reify ThreadFactory
      (newThread [_ r]
        (doto (thread (str prefix "-" (.incrementAndGet n)) r)
          (.setDaemon true))))))
