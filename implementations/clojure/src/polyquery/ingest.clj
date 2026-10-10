(ns polyquery.ingest
  "Entry point for table ingestion: opens the source (file inside the data
  directory or inline text), enforces size limits and dispatches on format."
  (:require [polyquery.errors :as err]
            [polyquery.ingest.csv :as csv]
            [polyquery.ingest.json :as json])
  (:import (java.io File FileInputStream InputStreamReader Reader StringReader IOException
                    FileNotFoundException)
           (java.nio.charset CharacterCodingException CodingErrorAction StandardCharsets)))

(set! *warn-on-reflection* true)

(defn- utf8-reader ^Reader [^java.io.InputStream in]
  (InputStreamReader. in (-> StandardCharsets/UTF_8
                             .newDecoder
                             (.onMalformedInput CodingErrorAction/REPORT)
                             (.onUnmappableCharacter CodingErrorAction/REPORT))))

(defn- utf8-length ^long [^String s]
  (let [n (.length s)]
    (if (<= (* 3 n) Integer/MAX_VALUE)
      (loop [i 0 acc 0]
        (if (< i n)
          (let [c (int (.charAt s i))]
            (recur (inc i) (+ acc (long (cond (< c 0x80) 1 (< c 0x800) 2
                                        (Character/isSurrogate (char c)) 2
                                        :else 3)))))
          acc))
      (* 3 n))))

(defn- check-size! [^long bytes limits]
  (when (> bytes (long (:max-ingest-bytes limits)))
    (err/fail! "RESOURCE_LIMIT" (str "input of " bytes " bytes exceeds the ingestion limit of "
                                     (:max-ingest-bytes limits) " bytes"))))

(defn- open-source
  "Returns a Reader for {:file File} or {:text String}."
  ^Reader [{:keys [^File file ^String text]} limits]
  (if file
    (do
      (when-not (.exists file)
        (err/fail! "NOT_FOUND" (str "file not found: " (.getName file))))
      (when (.isDirectory file)
        (err/fail! "IO_ERROR" (str "path is a directory: " (.getName file))))
      (check-size! (.length file) limits)
      (try (utf8-reader (FileInputStream. file))
           (catch FileNotFoundException e
             (err/fail! "IO_ERROR" (str "cannot open file: " (.getMessage e))))))
    (do (check-size! (utf8-length text) limits)
        (StringReader. text))))

(defn load-table
  "Parses a table. spec keys: :name :format (\"csv\"|\"json\"|\"jsonl\")
  :source ({:file f} or {:text s}) :schema (vector of Column or nil)
  :header? :delimiter :limits."
  [{:keys [format source limits] :as spec}]
  (with-open [r (open-source source limits)]
    (try
      (case format
        "csv" (csv/load-csv r spec)
        "json" (json/load-json r spec)
        "jsonl" (json/load-jsonl r spec))
      (catch CharacterCodingException _
        (err/fail! "INGEST_ERROR" "input is not valid UTF-8"))
      (catch IOException e
        (err/fail! "IO_ERROR" (str "I/O error while reading input: " (.getMessage e)))))))
