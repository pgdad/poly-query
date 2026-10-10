(ns polyquery.ingest.csv
  "Streaming RFC 4180 CSV reader and CSV table loading (ingestion.md §1)."
  (:require [polyquery.ingest.common :as c]
            [polyquery.storage.table :as table]
            [polyquery.util.text :as text])
  (:import (java.io Reader)
           (java.util ArrayList)))

(set! *warn-on-reflection* true)

(definterface ICharSource
  (^long next [])
  (^long peek []))

(deftype CharSource [^Reader r ^chars buf
                     ^:unsynchronized-mutable ^long pos
                     ^:unsynchronized-mutable ^long lim]
  ICharSource
  (next [this]
    (if (< pos lim)
      (let [ch (aget buf pos)] (set! pos (inc pos)) (long (int ch)))
      (let [n (.read r buf 0 (alength buf))]
        (if (neg? n)
          -1
          (do (set! lim (long n)) (set! pos 1) (long (int (aget buf 0))))))))
  (peek [this]
    (if (< pos lim)
      (long (int (aget buf pos)))
      (let [n (.read r buf 0 (alength buf))]
        (if (neg? n)
          -1
          (do (set! lim (long n)) (set! pos 0) (long (int (aget buf 0)))))))))

(defn char-source ^CharSource [^Reader r]
  (CharSource. r (char-array 65536) 0 0))

(def ^:private QUOTE (long \"))
(def ^:private LF (long \newline))
(def ^:private CR (long \return))

(defn- field-too-long! [record]
  (c/ingest-error! (str "record " record ": field longer than 16 MiB") {"record" record}))

(defn read-record
  "Reads one record into `fields` (cleared first). Returns false at end of
  input. Empty lines are skipped. Fields are Strings, or nil for an unquoted
  empty field."
  [^CharSource src ^long delim ^ArrayList fields record]
  (.clear fields)
  ;; skip completely empty lines
  (let [first-ch (loop []
                   (let [ch (.peek src)]
                     (cond
                       (= ch LF) (do (.next src) (recur))
                       (and (= ch CR)) (do (.next src)
                                           (if (= (.peek src) LF)
                                             (do (.next src) (recur))
                                             ;; lone CR starts a field
                                             CR))
                       :else ch)))]
    (if (= first-ch -1)
      false
      (let [sb (StringBuilder.)
            pending-cr? (if (= first-ch CR) true false)]
        (loop [pending-cr? pending-cr?]
          ;; at the start of a field
          (.setLength sb 0)
          (let [ch (if pending-cr? CR (.next src))]
            (if (= ch QUOTE)
              ;; quoted field
              (let [end (loop []
                          (let [ch (.next src)]
                            (cond
                              (= ch -1) (c/ingest-error! (str "record " record ": unterminated quoted field")
                                                         {"record" record})
                              (= ch QUOTE) (if (= (.peek src) QUOTE)
                                             (do (.next src) (.append sb \") (recur))
                                             (.next src))
                              :else (do (.append sb (char ch))
                                        (when (> (.length sb) c/max-field-chars) (field-too-long! record))
                                        (recur)))))]
                (.add fields (.toString sb))
                (cond
                  (= end delim) (recur false)
                  (or (= end LF) (= end -1)) true
                  (= end CR) (case (.peek src)
                               10 (do (.next src) true)
                               -1 true
                               (c/ingest-error! (str "record " record ": unexpected character after closing quote")
                                                {"record" record}))
                  :else (c/ingest-error! (str "record " record ": unexpected character after closing quote")
                                         {"record" record})))
              ;; unquoted field
              (let [end (loop [ch ch]
                          (cond
                            (or (= ch delim) (= ch LF) (= ch -1)) ch
                            (and (= ch CR) (= (.peek src) LF)) (do (.next src) LF)
                            (and (= ch CR) (= (.peek src) -1)) LF
                            :else (do (.append sb (char ch))
                                      (when (> (.length sb) c/max-field-chars) (field-too-long! record))
                                      (recur (.next src)))))]
                (.add fields (when (pos? (.length sb)) (.toString sb)))
                (if (= end delim)
                  (recur false)
                  true)))))))))

(defn load-csv
  "Loads CSV from a Reader. opts: :name :schema (vector of Column or nil)
  :header? :delimiter (char) :limits."
  [^Reader reader {:keys [name schema header? delimiter limits]}]
  (let [src (char-source reader)
        _ (when (= (.peek src) 0xFEFF) (.next src))
        delim (long (int delimiter))
        fields (ArrayList.)
        header (when header?
                 (when-not (read-record src delim fields 1)
                   (c/ingest-error! "missing CSV header"))
                 (mapv #(or % "") fields))
        names (if schema (mapv :name schema) header)
        _ (c/validate-column-names! names)
        _ (when (and header schema)
            (when-not (and (= (count header) (count schema))
                           (every? true? (map #(= (text/ascii-lower %1) (text/ascii-lower %2))
                                              header names)))
              (c/ingest-error! "CSV header does not match the explicit schema")))
        ncols (count names)
        buffers (c/new-column-buffers ncols)
        first-record (if header? 2 1)
        rows (loop [record first-record rows 0]
               (if (read-record src delim fields record)
                 (do
                   (when-not (= (.size fields) ncols)
                     (c/ingest-error! (str "record " record " has " (.size fields) " fields, expected " ncols)
                                      {"record" record}))
                   (dotimes [i ncols] (.add ^ArrayList (nth buffers i) (.get fields i)))
                   (when (zero? (rem rows 65536)) (c/check-row-limit! (inc rows) limits))
                   (recur (inc record) (inc rows)))
                 rows))
        _ (c/check-row-limit! rows limits)
        types (if schema
                (mapv :type schema)
                (mapv c/infer-text-type buffers))
        data (mapv #(c/convert-text-column %1 %2 %3 first-record) buffers types names)]
    (table/make-table name (c/make-columns names types) data rows)))
