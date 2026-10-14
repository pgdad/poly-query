(ns pqledger.text
  "Small text helpers shared by the file readers: ASCII case mapping,
  space/tab trimming, line splitting and strict UTF-8 decoding."
  (:require [clojure.string :as str])
  (:import (java.nio ByteBuffer)
           (java.nio.charset CharacterCodingException CodingErrorAction StandardCharsets)))

(set! *warn-on-reflection* true)

(defn ascii-upper
  "s with the ASCII letters a-z upper-cased; other characters unchanged."
  ^String [^String s]
  (let [sb (StringBuilder. (.length s))]
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (.append sb (if (and (>= (int c) (int \a)) (<= (int c) (int \z)))
                      (char (- (int c) 32))
                      c))))
    (.toString sb)))

(defn ascii-lower
  ^String [^String s]
  (let [sb (StringBuilder. (.length s))]
    (dotimes [i (.length s)]
      (let [c (.charAt s i)]
        (.append sb (if (and (>= (int c) (int \A)) (<= (int c) (int \Z)))
                      (char (+ (int c) 32))
                      c))))
    (.toString sb)))

(defn- blank-char? [c] (or (= c \space) (= c \tab)))

(defn trim
  "s without leading and trailing spaces and tabs (only those)."
  ^String [^String s]
  (let [n (.length s)
        start (loop [i 0] (if (and (< i n) (blank-char? (.charAt s i))) (recur (inc i)) i))
        end (loop [i n] (if (and (> i start) (blank-char? (.charAt s (dec i)))) (recur (dec i)) i))]
    (subs s start end)))

(defn code-points
  "Length of s in Unicode code points."
  ^long [^String s]
  (.codePointCount s 0 (.length s)))

(defn decode-utf8
  "Strict UTF-8 decoding of bytes (nil when they are not valid UTF-8); a
  leading byte order mark is removed."
  [^bytes bs]
  (try
    (let [s (.toString (.decode (-> StandardCharsets/UTF_8
                                    .newDecoder
                                    (.onMalformedInput CodingErrorAction/REPORT)
                                    (.onUnmappableCharacter CodingErrorAction/REPORT))
                                (ByteBuffer/wrap bs)))]
      (if (str/starts-with? s "﻿") (subs s 1) s))
    (catch CharacterCodingException _ nil)))

(defn lines
  "The lines of a text with \\n or \\r\\n line ends (a final line end does not
  start another line)."
  [^String s]
  (let [ls (str/split s #"\n" -1)
        ls (if (= "" (peek ls)) (pop ls) ls)]
    (mapv #(if (str/ends-with? % "\r") (subs % 0 (dec (count %))) %) ls)))
