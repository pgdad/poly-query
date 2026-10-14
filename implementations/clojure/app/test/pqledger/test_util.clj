(ns pqledger.test-util
  (:require [pqledger.errors :as errors])
  (:import (java.io File)
           (java.nio.file Files)
           (java.nio.file.attribute FileAttribute)))

(defmacro error-kind
  "The application error kind thrown by body (e.g. :config), or :no-error."
  [& body]
  `(try ~@body :no-error
        (catch clojure.lang.ExceptionInfo e# (or (errors/kind e#) (throw e#)))))

(defn temp-dir ^File []
  (.toFile (Files/createTempDirectory "pqledger-test" (make-array FileAttribute 0))))

(defn write-file!
  "Writes text to dir/name; returns the File."
  ^File [^File dir name ^String text]
  (let [f (File. dir ^String name)]
    (.mkdirs (.getParentFile f))
    (spit f text :encoding "UTF-8")
    f))
