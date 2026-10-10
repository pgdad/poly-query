(ns polyquery.test-util
  (:require [polyquery.errors :as err]))

(defmacro error-code
  "Evaluates body and returns the engine error code it throws (or :no-error)."
  [& body]
  `(try ~@body :no-error
        (catch clojure.lang.ExceptionInfo e# (or (err/error-code e#) (throw e#)))))
