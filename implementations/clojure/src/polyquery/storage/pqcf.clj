(ns polyquery.storage.pqcf
  "PQCF v1 columnar file format (spec/storage/pqcf-v1.md).

  Writing: chunks are written column by column (each row group's chunk of a
  column in turn), 8-byte aligned, followed by the JSON metadata and the
  footer; the file is written to a temporary file in the target directory,
  fsync'ed and atomically renamed over the target, then the directory is
  fsync'ed (§5).

  Reading: the header, footer, metadata checksum and the metadata structure
  are validated at open. Chunks are then either read, checksummed, validated
  and decoded eagerly, or — with memory mapping — mapped at open and
  checksummed/validated/decoded lazily on first access (a failing chunk makes
  the query fail with STORAGE_CORRUPT). Fixed-width PLAIN chunks of mapped
  files are read in place (zero copy)."
  (:require [clojure.string :as str]
            [polyquery.errors :as err]
            [polyquery.storage.column :as col]
            [polyquery.storage.table :as table]
            [polyquery.types :as t]
            [polyquery.util.json :as json]
            [polyquery.util.text :as text]
            [polyquery.values :as v])
  (:import (java.io BufferedOutputStream File FileOutputStream IOException OutputStream)
           (java.nio BufferUnderflowException ByteBuffer ByteOrder)
           (java.nio.channels FileChannel FileChannel$MapMode)
           (java.nio.charset CharacterCodingException CharsetDecoder CodingErrorAction
                             StandardCharsets)
           (java.nio.file CopyOption Files OpenOption StandardCopyOption StandardOpenOption)
           (java.util HashMap)
           (java.util.concurrent.atomic AtomicLong)
           (java.util.zip CRC32)
           (polyquery.storage.column BooleanVector DictVector DoubleVector LongVector StringVector
                                     BufferDoubleVector BufferIntVector BufferLongVector)))

(set! *warn-on-reflection* true)

(def format-version 1)
(def writer-name "polyquery-clojure 0.1.0")
(def default-row-group-size 65536)

(def ^:private ^"[B" magic (.getBytes "PQCF" StandardCharsets/US_ASCII))

(defn- corrupt! [msg] (err/fail! "STORAGE_CORRUPT" msg))
(defn- unsupported! [msg] (err/fail! "STORAGE_VERSION_UNSUPPORTED" msg))

(defn- crc32 ^long [^ByteBuffer buf]
  (let [c (CRC32.)]
    (.update c (.duplicate buf))
    (.getValue c)))

(defn- le ^ByteBuffer [^ByteBuffer b] (.order b ByteOrder/LITTLE_ENDIAN))

(def ^:private min-date (v/days-from-civil 1 1 1))
(def ^:private max-date (v/days-from-civil 9999 12 31))
(def ^:private min-timestamp (* (long min-date) (long v/micros-per-day)))
(def ^:private max-timestamp (dec (* (inc (long max-date)) (long v/micros-per-day))))

(defn- rle-type? [t] (contains? #{:boolean :int64 :decimal :date :timestamp} (t/kind t)))

;; ===========================================================================
;; Writing

(defn- bitmap-bytes ^long [^long n] (quot (+ n 7) 8))

(defn- put-bitmap!
  "Writes an LSB-first bitmap of (pred i) for i < n."
  [^ByteBuffer buf ^long n pred]
  (let [nb (bitmap-bytes n)]
    (dotimes [b nb]
      (let [byte-val (loop [k 0 acc 0]
                       (if (< k 8)
                         (let [i (+ (* b 8) k)]
                           (recur (inc k) (if (and (< i n) (pred i)) (bit-or acc (bit-shift-left 1 k)) (long acc))))
                         acc))]
        (.put buf (unchecked-byte byte-val))))))

(defn- long-value
  "Integer representation of a non-null value for fixed-width/RLE encodings."
  ^long [kind x]
  (if (= kind :boolean) (if x 1 0) (long x)))

(defn- runs-of
  "Run-length runs [[value length] …] of the values; NULL slots extend the
  current run (their value is ignored by readers)."
  [kind ^objects vals]
  (let [n (alength vals)
        out (java.util.ArrayList.)]
    (loop [i 0 cur nil len 0]
      (if (< i n)
        (let [x (aget vals i)
              xv (if (nil? x) cur (long-value kind x))]
          (cond
            (nil? cur) (recur (inc i) (or xv 0) 1)
            (= (long xv) (long cur)) (recur (inc i) cur (inc len))
            :else (do (.add out [cur len]) (recur (inc i) xv 1))))
        (when (pos? len) (.add out [cur len]))))
    (vec out)))

(defn- utf8 ^bytes [^String s] (.getBytes s StandardCharsets/UTF_8))

(defn- string-plain-size ^long [^objects encoded]
  (+ (* 4 (inc (alength encoded)))
     (areduce encoded i acc 0 (+ acc (long (if-let [b (aget encoded i)] (alength ^bytes b) 0))))))

(defn- dictionary-of
  "[dictionary entries (byte arrays), codes] of a STRING chunk."
  [^objects vals]
  (let [ids (HashMap.)
        entries (java.util.ArrayList.)
        codes (int-array (alength vals))]
    (dotimes [i (alength vals)]
      (when-some [s (aget vals i)]
        (let [code (or (.get ids s)
                       (let [c (.size ids)] (.put ids s c) (.add entries (utf8 s)) c))]
          (aset codes i (int code)))))
    [(vec entries) codes]))

(defn- choose-encoding
  "Encoding of a chunk: forced (\"plain\" \"dict\" \"rle\") where applicable,
  else the smallest of the applicable encodings."
  [requested t ^objects vals encoded-strings dict runs]
  (let [kind (t/kind t)
        n (alength vals)]
    (case requested
      "plain" "PLAIN"
      "dict" (if (= kind :string) "DICT" "PLAIN")
      "rle" (if (rle-type? t) "RLE" "PLAIN")
      (cond
        (= kind :string)
        (let [[entries] dict
              dict-size (+ 4 (* 4 (inc (count entries))) (reduce + 0 (map #(alength ^bytes %) entries))
                           (* 4 n))]
          (if (< dict-size (string-plain-size encoded-strings)) "DICT" "PLAIN"))
        (rle-type? t)
        (let [plain (case kind :boolean (bitmap-bytes n) :date (* 4 n) (* 8 n))]
          (if (< (+ 4 (* 12 (count runs))) plain) "RLE" "PLAIN"))
        :else "PLAIN"))))

(defn- encode-chunk
  "Encodes the values of one column chunk. Returns {:bytes ByteBuffer
  :encoding :null-count}."
  [t ^objects vals requested]
  (let [kind (t/kind t)
        n (alength vals)
        nulls (count (filter nil? vals))
        encoded (when (= kind :string)
                  (let [a (object-array n)]
                    (dotimes [i n] (when-some [s (aget vals i)] (aset a i (utf8 s))))
                    a))
        dict (when (and (= kind :string) (not= requested "plain")) (dictionary-of vals))
        runs (when (and (rle-type? t) (not= requested "plain")) (runs-of kind vals))
        encoding (choose-encoding requested t vals encoded dict runs)
        validity-size (if (pos? nulls) (bitmap-bytes n) 0)
        body-size (case encoding
                    "PLAIN" (case kind
                              :boolean (bitmap-bytes n)
                              :date (* 4 n)
                              (:int64 :decimal :timestamp :float64) (* 8 n)
                              :string (string-plain-size encoded))
                    "DICT" (let [[entries] dict]
                             (+ 4 (* 4 (inc (count entries)))
                                (reduce + 0 (map #(alength ^bytes %) entries)) (* 4 n)))
                    "RLE" (+ 4 (* 12 (count runs))))
        buf (le (ByteBuffer/allocate (+ validity-size body-size)))]
    (when (pos? nulls) (put-bitmap! buf n #(some? (aget vals (int %)))))
    (case encoding
      "PLAIN"
      (case kind
        :boolean (put-bitmap! buf n #(true? (aget vals (int %))))
        :date (dotimes [i n] (.putInt buf (int (or (aget vals i) 0))))
        (:int64 :decimal :timestamp) (dotimes [i n] (.putLong buf (long (or (aget vals i) 0))))
        :float64 (dotimes [i n] (.putDouble buf (double (or (aget vals i) 0.0))))
        :string (do (loop [i 0 off 0]
                      (.putInt buf (unchecked-int off))
                      (when (< i n)
                        (recur (inc i) (+ off (long (if-let [b (aget encoded i)] (alength ^bytes b) 0))))))
                    (dotimes [i n] (when-let [b (aget encoded i)] (.put buf ^bytes b)))))
      "DICT"
      (let [[entries ^ints codes] dict]
        (.putInt buf (int (count entries)))
        (loop [es entries off 0]
          (.putInt buf (unchecked-int off))
          (when-let [e (first es)]
            (recur (next es) (+ off (alength ^bytes e)))))
        (doseq [e entries] (.put buf ^bytes e))
        (dotimes [i n] (.putInt buf (aget codes i))))
      "RLE"
      (do (.putInt buf (int (count runs)))
          (doseq [[x len] runs]
            (.putLong buf (long x))
            (.putInt buf (int len)))))
    (.flip buf)
    {:bytes buf :encoding encoding :null-count nulls}))

(defn- min-max
  "[min max] of the non-null values (nil when none)."
  [t ^objects vals]
  (let [cmp (v/value-comparator t)]
    (areduce vals i acc [nil nil]
             (let [x (aget vals i)
                   [mn mx] acc]
               (if (nil? x)
                 acc
                 [(if (or (nil? mn) (neg? (.compare cmp x mn))) x mn)
                  (if (or (nil? mx) (pos? (.compare cmp x mx))) x mx)])))))

(defn- chunk-meta
  [offset t {:keys [^ByteBuffer bytes encoding null-count]} vals]
  (let [[mn mx] (when-not (= :string (t/kind t)) (min-max t vals))]
    (cond-> (array-map "offset" offset "length" (.remaining bytes) "crc32" (crc32 bytes)
                       "encoding" encoding "null_count" null-count)
      (some? mn) (assoc "min" (v/value->json t mn) "max" (v/value->json t mx)))))

(defn- write-padding! [^OutputStream out ^long pos]
  (let [pad (rem (- 8 (rem pos 8)) 8)]
    (dotimes [_ pad] (.write out 0))
    (+ pos pad)))

(defn- write-buffer! [^OutputStream out ^ByteBuffer buf]
  (if (.hasArray buf)
    (.write out (.array buf) (+ (.arrayOffset buf) (.position buf)) (.remaining buf))
    (let [b (byte-array (.remaining buf))]
      (.get (.duplicate buf) b)
      (.write out b))))

(defn- write-pqcf!
  "Writes table `tbl` in PQCF to `out`; returns the number of bytes."
  [^OutputStream out tbl {:keys [row-group-size encoding]}]
  (let [n (long (:row-count tbl))
        rg (long (or row-group-size default-row-group-size))
        groups (vec (for [start (range 0 n rg)] [start (min rg (- n start))]))
        columns (:columns tbl)
        header (le (ByteBuffer/allocate 8))
        _ (do (.put header magic) (.putShort header (short format-version)) (.putShort header (short 0))
              (.flip header) (write-buffer! out header))
        ;; chunk metadata per column, per group
        [pos chunk-metas]
        (reduce (fn [[pos acc] [ci c]]
                  (let [^objects vals (table/column-array tbl ci)
                        t (:type c)]
                    (reduce (fn [[pos acc] [start len]]
                              (let [pos (write-padding! out pos)
                                    chunk-vals (java.util.Arrays/copyOfRange vals (int start) (int (+ start len)))
                                    enc (encode-chunk t chunk-vals encoding)
                                    size (.remaining ^ByteBuffer (:bytes enc))]
                                (write-buffer! out (:bytes enc))
                                [(+ pos size) (update acc ci (fnil conj []) (chunk-meta pos t enc chunk-vals))]))
                            [pos acc] groups)))
                [8 {}]
                (map-indexed vector columns))
        meta (array-map
              "format_version" format-version
              "writer" writer-name
              "table" (:name tbl)
              "row_count" n
              "columns" (table/columns-json columns)
              "indexes" (mapv (fn [idx] {"name" (:name idx) "column" (:column idx)
                                         "kind" (if (= :hash (:kind idx)) "HASH" "BTREE")})
                              (:indexes tbl))
              "row_groups" (vec (map-indexed
                                 (fn [g [_ len]]
                                   {"row_count" len
                                    "chunks" (mapv #(nth (get chunk-metas %) g) (range (count columns)))})
                                 groups)))
        meta-bytes (le (ByteBuffer/wrap (utf8 (json/write-str meta))))
        footer (le (ByteBuffer/allocate 12))]
    (write-buffer! out meta-bytes)
    (.putInt footer (.remaining meta-bytes))
    (.putInt footer (unchecked-int (crc32 meta-bytes)))
    (.put footer magic)
    (.flip footer)
    (write-buffer! out footer)
    (+ (long pos) (.remaining meta-bytes) 12)))

(def ^:private tmp-counter (AtomicLong.))

(defn- remove-stale-temp-files!
  "Removes temporary files left by crashed saves to the same target."
  [^File dir ^String target-name]
  (let [prefix (str "." target-name ".tmp-")]
    (doseq [^File f (.listFiles dir)]
      (when (str/starts-with? (.getName f) prefix)
        (.delete f)))))

(defn- fsync-directory! [^File dir]
  (try
    (with-open [ch (FileChannel/open (.toPath dir) (into-array OpenOption [StandardOpenOption/READ]))]
      (.force ch true))
    (catch IOException _ nil)))

(defn save!
  "Atomically writes table `tbl` as PQCF file `target` (§5). opts:
  {:row-group-size n :encoding \"auto\"|\"plain\"|\"dict\"|\"rle\"}. Returns the
  file size."
  [tbl ^File target opts]
  (let [target (.getAbsoluteFile target)
        dir (.getParentFile target)]
    (when-not (and dir (.isDirectory dir))
      (err/fail! "IO_ERROR" "the target directory does not exist"))
    (when (.isDirectory target)
      (err/fail! "IO_ERROR" "the target path is a directory"))
    (remove-stale-temp-files! dir (.getName target))
    (let [tmp (File. dir (str "." (.getName target) ".tmp-" (.pid (java.lang.ProcessHandle/current)) "-"
                              (System/nanoTime) "-" (.incrementAndGet ^AtomicLong tmp-counter)))]
      (try
        (let [size (with-open [fos (FileOutputStream. tmp)]
                     (let [out (BufferedOutputStream. fos (* 1024 1024))
                           size (write-pqcf! out tbl opts)]
                       (.flush out)
                       (.sync (.getFD fos))
                       size))]
          (Files/move (.toPath tmp) (.toPath target)
                      (into-array CopyOption [StandardCopyOption/ATOMIC_MOVE StandardCopyOption/REPLACE_EXISTING]))
          (fsync-directory! dir)
          size)
        (catch IOException e
          (.delete tmp)
          (err/fail! "IO_ERROR" (str "cannot write file: " (.getMessage e))))
        (catch Throwable e
          (.delete tmp)
          (throw e))))))

;; ===========================================================================
;; Reading: chunk decoding

(defn- u32 ^long [^ByteBuffer buf ^long pos] (Integer/toUnsignedLong (.getInt buf (int pos))))

(defn- strict-decoder ^CharsetDecoder []
  (-> StandardCharsets/UTF_8 .newDecoder
      (.onMalformedInput CodingErrorAction/REPORT)
      (.onUnmappableCharacter CodingErrorAction/REPORT)))

(defn- decode-utf8 ^String [^CharsetDecoder dec ^ByteBuffer buf ^long start ^long end]
  (if (= start end)
    ""
    (let [slice (-> (.duplicate buf) (.limit (int end)) (.position (int start)))]
      (try (.toString (.decode (.reset dec) ^ByteBuffer slice))
           (catch CharacterCodingException _ (corrupt! "invalid UTF-8 in a STRING chunk"))))))

(defn- read-validity
  "Validity bitmap (long words) of the first n bits at pos; checks that it
  has exactly null-count zero bits."
  ^longs [^ByteBuffer buf ^long pos ^long n ^long null-count]
  (let [bits (long-array (col/bitmap-words n))]
    (dotimes [i n]
      (when-not (zero? (bit-and (.get buf (int (+ pos (quot i 8)))) (bit-shift-left 1 (rem i 8))))
        (col/set-bit! bits i)))
    (let [valid (reduce + 0 (map #(Long/bitCount %) bits))]
      (when-not (= (- n valid) null-count)
        (corrupt! "validity bitmap does not match null_count")))
    bits))

(defn- value-checker
  "Returns (fn [^long x]) throwing STORAGE_CORRUPT for an invalid stored
  value of type t (integer-represented types)."
  [t]
  (case (t/kind t)
    :decimal (let [p (t/precision t)]
               (fn [^long x] (when-not (v/fits-precision? x p) (corrupt! "DECIMAL value exceeds its precision"))))
    :date (fn [^long x] (when-not (<= (long min-date) x (long max-date)) (corrupt! "DATE value out of range")))
    :timestamp (fn [^long x] (when-not (<= (long min-timestamp) x (long max-timestamp))
                               (corrupt! "TIMESTAMP value out of range")))
    :boolean (fn [^long x] (when-not (or (= x 0) (= x 1)) (corrupt! "BOOLEAN RLE value is not 0/1")))
    (fn [^long _] nil)))

(defn- valid-row? [^longs validity ^long i] (or (nil? validity) (col/bit-set? validity i)))

(defn- expect-length! [^long expected ^long actual]
  (when-not (= expected actual)
    (corrupt! "chunk size does not match its encoding")))

(defn- decode-plain
  [t ^ByteBuffer buf pos n validity len mmap?]
  (let [pos (long pos) n (long n) len (long len)
        kind (t/kind t)
        check (value-checker t)]
    (case kind
      :boolean
      (do (expect-length! (+ pos (bitmap-bytes n)) len)
          (let [bits (long-array (col/bitmap-words n))]
            (dotimes [i n]
              (when-not (zero? (bit-and (.get buf (int (+ pos (quot i 8)))) (bit-shift-left 1 (rem i 8))))
                (col/set-bit! bits i)))
            (BooleanVector. bits validity n)))

      (:int64 :decimal :timestamp)
      (do (expect-length! (+ pos (* 8 n)) len)
          (dotimes [i n] (when (valid-row? validity i) (check (.getLong buf (int (+ pos (* 8 i)))))))
          (if mmap?
            (BufferLongVector. buf pos validity n)
            (let [a (long-array n)]
              (dotimes [i n] (aset a i (.getLong buf (int (+ pos (* 8 i))))))
              (LongVector. a validity n))))

      :date
      (do (expect-length! (+ pos (* 4 n)) len)
          (dotimes [i n] (when (valid-row? validity i) (check (long (.getInt buf (int (+ pos (* 4 i))))))))
          (if mmap?
            (BufferIntVector. buf pos validity n)
            (let [a (long-array n)]
              (dotimes [i n] (aset a i (long (.getInt buf (int (+ pos (* 4 i)))))))
              (LongVector. a validity n))))

      :float64
      (do (expect-length! (+ pos (* 8 n)) len)
          (dotimes [i n]
            (when (valid-row? validity i)
              (let [d (.getDouble buf (int (+ pos (* 8 i))))]
                (when (or (Double/isNaN d) (Double/isInfinite d)) (corrupt! "non-finite FLOAT64 value")))))
          (if mmap?
            (BufferDoubleVector. buf pos validity n)
            (let [a (double-array n)]
              (dotimes [i n] (aset a i (.getDouble buf (int (+ pos (* 8 i))))))
              (DoubleVector. a validity n))))

      :string
      (let [offsets-end (+ pos (* 4 (inc n)))
            _ (when (> offsets-end len) (corrupt! "STRING offsets exceed the chunk"))
            total (u32 buf (+ pos (* 4 n)))
            _ (expect-length! (+ offsets-end total) len)
            dec (strict-decoder)
            vals (object-array n)]
        (when-not (zero? (u32 buf pos)) (corrupt! "first STRING offset is not 0"))
        (dotimes [i n]
          (let [s (u32 buf (+ pos (* 4 i)))
                e (u32 buf (+ pos (* 4 (inc i))))]
            (when (< e s) (corrupt! "decreasing STRING offsets"))
            (when (valid-row? validity i)
              (aset vals i (decode-utf8 dec buf (+ offsets-end s) (+ offsets-end e))))))
        (StringVector. vals validity n)))))

(defn- decode-dict
  [t ^ByteBuffer buf pos n validity len]
  (let [pos (long pos) n (long n) len (long len)]
  (when-not (= :string (t/kind t)) (corrupt! "DICT encoding on a non-STRING column"))
  (when (> (+ pos 4) len) (corrupt! "truncated DICT chunk"))
  (let [d (u32 buf pos)
        offsets-start (+ pos 4)
        bytes-start (+ offsets-start (* 4 (inc d)))
        _ (when (> bytes-start len) (corrupt! "DICT offsets exceed the chunk"))
        total (u32 buf (+ offsets-start (* 4 d)))
        codes-start (+ bytes-start total)
        _ (expect-length! (+ codes-start (* 4 n)) len)
        dec (strict-decoder)
        dict (object-array d)
        codes (int-array n)]
    (when-not (zero? (u32 buf offsets-start)) (corrupt! "first DICT offset is not 0"))
    (dotimes [k d]
      (let [s (u32 buf (+ offsets-start (* 4 k)))
            e (u32 buf (+ offsets-start (* 4 (inc k))))]
        (when (< e s) (corrupt! "decreasing DICT offsets"))
        (aset dict k (decode-utf8 dec buf (+ bytes-start s) (+ bytes-start e)))))
    (dotimes [i n]
      (when (valid-row? validity i)
        (let [code (u32 buf (+ codes-start (* 4 i)))]
          (when (>= code d) (corrupt! "dictionary code out of range"))
          (aset codes i (int code)))))
    (DictVector. codes dict validity n))))

(defn- decode-rle
  [t ^ByteBuffer buf pos n validity len]
  (let [pos (long pos) n (long n) len (long len)]
  (when-not (rle-type? t) (corrupt! "RLE encoding on an unsupported column type"))
  (when (> (+ pos 4) len) (corrupt! "truncated RLE chunk"))
  (let [r (u32 buf pos)
        _ (expect-length! (+ pos 4 (* 12 r)) len)
        check (value-checker t)
        values (long-array n)]
    (loop [k 0 row 0]
      (if (< k r)
        (let [at (+ pos 4 (* 12 k))
              x (.getLong buf (int at))
              run (u32 buf (+ at 8))]
          (when (or (zero? run) (> (+ row run) n)) (corrupt! "invalid RLE run length"))
          (when (some #(valid-row? validity %) (range row (+ row run)))
            (check x))
          (java.util.Arrays/fill values (int row) (int (+ row run)) x)
          (recur (inc k) (+ row run)))
        (when-not (= row n) (corrupt! "RLE runs do not cover the row group"))))
    (if (= :boolean (t/kind t))
      (let [bits (long-array (col/bitmap-words n))]
        (dotimes [i n] (when (= 1 (aget values i)) (col/set-bit! bits i)))
        (BooleanVector. bits validity n))
      (LongVector. values validity n)))))

(defn- decode-chunk
  "Verifies and decodes one chunk held in buf (position 0, little endian)."
  [t ^ByteBuffer buf {:keys [crc encoding null-count]} n mmap?]
  (when-not (= (long crc) (crc32 buf))
    (corrupt! "column chunk checksum mismatch"))
  (try
    (let [len (.remaining buf)
          validity (when (pos? (long null-count))
                     (when (> (bitmap-bytes n) len) (corrupt! "truncated validity bitmap"))
                     (read-validity buf 0 n null-count))
          pos (if validity (bitmap-bytes n) 0)]
      (case encoding
        "PLAIN" (decode-plain t buf pos n validity len mmap?)
        "DICT" (decode-dict t buf pos n validity len)
        "RLE" (decode-rle t buf pos n validity len)))
    (catch IndexOutOfBoundsException _ (corrupt! "column chunk is truncated"))
    (catch BufferUnderflowException _ (corrupt! "column chunk is truncated"))))

;; ===========================================================================
;; Reading: header, footer, metadata

(defn- read-fully ^ByteBuffer [^FileChannel ch ^long pos ^long len]
  (let [buf (le (ByteBuffer/allocate (int len)))]
    (loop [p pos]
      (when (.hasRemaining buf)
        (let [k (.read ch buf p)]
          (when (neg? k) (corrupt! "unexpected end of file"))
          (recur (+ p k)))))
    (.flip buf)
    buf))

(defn- int-value
  "A JSON integer as a long, or nil."
  [x]
  (when (instance? Long x) (long x)))

(defn- req-int [m k lo hi what]
  (let [x (int-value (get m k))]
    (when-not (and x (<= lo (long x) hi))
      (corrupt! (str "invalid or missing '" k "' in " what)))
    (long x)))

(defn- parse-stat
  "Chunk min/max statistic as a runtime value of type t, or nil when absent
  or not understood (statistics are only used for row-group skipping)."
  [t x]
  (try
    (when (some? x)
      (case (t/kind t)
        :int64 (int-value x)
        :float64 (cond (instance? Double x) x (instance? Long x) (double (long x)))
        :boolean (when (boolean? x) x)
        :decimal (when (string? x) (v/parse-decimal-exact x (t/precision t) (t/scale t)))
        :date (when (string? x) (v/parse-date x))
        :timestamp (when (string? x) (v/parse-timestamp x))
        nil))
    (catch Exception _ nil)))

(def ^:private encodings #{"PLAIN" "DICT" "RLE"})

(defn- parse-chunk
  [c t ^long rows ^long data-end]
  (when-not (map? c) (corrupt! "chunk entry is not an object"))
  (let [what "chunk metadata"
        offset (req-int c "offset" 8 data-end what)
        length (req-int c "length" 0 data-end what)
        crc (req-int c "crc32" 0 0xFFFFFFFF what)
        null-count (req-int c "null_count" 0 rows what)
        encoding (get c "encoding")]
    (when-not (string? encoding) (corrupt! "chunk encoding missing"))
    (when-not (encodings encoding)
      (unsupported! (str "unknown chunk encoding '" encoding "'")))
    (when (> (+ offset length) data-end) (corrupt! "chunk extends beyond the data region"))
    {:offset offset :length length :crc crc :encoding encoding :null-count null-count
     :min (parse-stat t (get c "min")) :max (parse-stat t (get c "max"))}))

(defn- parse-metadata
  [meta ^long header-version ^long data-end]
  (when-not (map? meta) (corrupt! "metadata is not a JSON object"))
  (when-not (= (int-value (get meta "format_version")) header-version)
    (corrupt! "metadata format_version does not match the header"))
  (when-not (string? (get meta "table")) (corrupt! "metadata has no table name"))
  (let [row-count (req-int meta "row_count" 0 Long/MAX_VALUE "metadata")
        cols (get meta "columns")
        _ (when-not (vector? cols) (corrupt! "metadata columns missing"))
        columns (mapv (fn [c]
                        (let [nm (get c "name") ty (get c "type")]
                          (when-not (and (map? c) (string? nm) (seq nm) (string? ty))
                            (corrupt! "invalid column entry"))
                          (table/->Column nm (t/parse-type-string ty "STORAGE_CORRUPT"))))
                      cols)
        _ (when-not (apply distinct? (cons ::none (map (comp text/ascii-lower :name) columns)))
            (corrupt! "duplicate column names"))
        idx-meta (get meta "indexes" [])
        _ (when-not (vector? idx-meta) (corrupt! "metadata indexes is not an array"))
        indexes (mapv (fn [x]
                        (let [nm (get x "name") cname (get x "column") kind (get x "kind")
                              ci (when (string? cname)
                                   (first (keep-indexed (fn [i c] (when (= (text/ascii-lower cname)
                                                                           (text/ascii-lower (:name c)))
                                                                    i))
                                                        columns)))]
                          (when-not (and (map? x) (string? nm) (seq nm) ci (string? kind)
                                         (#{"HASH" "BTREE"} (text/ascii-upper kind)))
                            (corrupt! "invalid index entry"))
                          {:name nm :column-index ci
                           :kind (if (= "HASH" (text/ascii-upper kind)) :hash :btree)}))
                      idx-meta)
        _ (when-not (apply distinct? (cons ::none (map (comp text/ascii-lower :name) indexes)))
            (corrupt! "duplicate index names"))
        groups (get meta "row_groups")
        _ (when-not (vector? groups) (corrupt! "metadata row_groups missing"))
        ncols (count columns)
        row-groups (mapv (fn [g]
                           (when-not (map? g) (corrupt! "row group is not an object"))
                           (let [rows (req-int g "row_count" 0 row-count "row group")
                                 chunks (get g "chunks")]
                             (when-not (and (vector? chunks) (= ncols (count chunks)))
                               (corrupt! "row group does not have one chunk per column"))
                             {:row-count rows
                              :chunks (mapv (fn [c column] (parse-chunk c (:type column) rows data-end))
                                            chunks columns)}))
                         groups)]
    (when-not (= row-count (reduce + 0 (map :row-count row-groups)))
      (corrupt! "row_count does not match the row groups"))
    {:table (get meta "table") :row-count row-count :columns columns :indexes indexes
     :row-groups row-groups}))

(defn- read-metadata
  "Validates header and footer and parses the metadata. Returns
  [metadata data-end]."
  [^FileChannel ch]
  (let [size (.size ch)
        _ (when (< size 8) (corrupt! "file is too small to be a PQCF file"))
        ^ByteBuffer header (read-fully ch 0 8)
        _ (when-not (= (.getInt header 0) (.getInt (le (ByteBuffer/wrap magic)) 0))
            (corrupt! "bad header magic"))
        version (long (.getShort header 4))
        flags (long (.getShort header 6))]
    (cond (zero? version) (corrupt! "format_version 0")
          (or (neg? version) (> version format-version))
          (unsupported! (str "PQCF format version " (bit-and version 0xFFFF) " is not supported"))
          (not (zero? flags)) (unsupported! "unsupported PQCF header flags"))
    (when (< size 20) (corrupt! "file is truncated"))
    (let [^ByteBuffer footer (read-fully ch (- size 12) 12)
          m (u32 footer 0)
          meta-crc (u32 footer 4)
          _ (when-not (= (.getInt footer 8) (.getInt (le (ByteBuffer/wrap magic)) 0))
              (corrupt! "bad trailing magic"))
          data-end (- size 12 m)
          _ (when (< data-end 8) (corrupt! "invalid metadata length"))
          meta-buf (read-fully ch data-end m)
          _ (when-not (= meta-crc (crc32 meta-buf)) (corrupt! "metadata checksum mismatch"))
          text (try (.toString (.decode (strict-decoder) meta-buf))
                    (catch CharacterCodingException _ (corrupt! "metadata is not valid UTF-8")))
          meta (try (json/read-str text)
                    (catch Exception _ (corrupt! "metadata is not valid JSON")))]
      [(parse-metadata meta version data-end) data-end])))

(defn- segments
  "Table segments of the row groups; chunk buffers are mapped (lazy
  decoding) or read and decoded eagerly."
  [^FileChannel ch {:keys [columns row-groups]} mmap?]
  (loop [gs row-groups start 0 acc []]
    (if-let [g (first gs)]
      (let [n (long (:row-count g))
            vectors (mapv (fn [c chunk]
                            (let [t (:type c)
                                  {:keys [offset length]} chunk]
                              (if mmap?
                                (let [buf (le (.map ch FileChannel$MapMode/READ_ONLY (long offset) (long length)))]
                                  (delay (decode-chunk t buf chunk n true)))
                                (decode-chunk t (read-fully ch offset length) chunk n false))))
                          columns (:chunks g))
            stats (mapv #(select-keys % [:min :max :null-count]) (:chunks g))]
        (recur (next gs) (+ start n) (conj acc (table/->Segment start n vectors stats))))
      acc)))

(defn open
  "Reads PQCF file f. opts: {:mmap? b}. Returns {:columns :row-count
  :segments :indexes [{:name :column-index :kind}]}."
  [^File f {:keys [mmap?]}]
  (when-not (.exists f) (err/fail! "NOT_FOUND" (str "file not found: " (.getName f))))
  (when (.isDirectory f) (err/fail! "IO_ERROR" (str "path is a directory: " (.getName f))))
  (try
    (with-open [ch (FileChannel/open (.toPath f) (into-array OpenOption [StandardOpenOption/READ]))]
      (let [[meta] (read-metadata ch)]
        (assoc (select-keys meta [:columns :row-count :indexes])
               :segments (segments ch meta mmap?))))
    (catch IOException e
      (err/fail! "IO_ERROR" (str "cannot read file: " (.getMessage e))))))
