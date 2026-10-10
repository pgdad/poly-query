(ns polyquery.util.text
  "Small string helpers shared by all layers.")

(set! *warn-on-reflection* true)

(defn ascii-lower
  "ASCII-only lower-casing (identifier matching is ASCII case-insensitive)."
  ^String [^String s]
  (let [n (.length s)]
    (loop [i 0]
      (cond
        (= i n) s
        (let [c (.charAt s i)] (and (>= (int c) 65) (<= (int c) 90)))
        (let [sb (StringBuilder. s)]
          (dotimes [j n]
            (let [c (.charAt s j)]
              (when (and (>= (int c) 65) (<= (int c) 90))
                (.setCharAt sb j (char (+ (int c) 32))))))
          (.toString sb))
        :else (recur (inc i))))))

(defn ascii-upper
  ^String [^String s]
  (let [sb (StringBuilder. s)]
    (dotimes [j (.length s)]
      (let [c (.charAt s j)]
        (when (and (>= (int c) 97) (<= (int c) 122))
          (.setCharAt sb j (char (- (int c) 32))))))
    (.toString sb)))

(defn trim-blank
  "Trims ASCII spaces and tabs from both ends."
  ^String [^String s]
  (let [n (.length s)
        start (loop [i 0]
                (if (and (< i n) (let [c (.charAt s i)] (or (= c \space) (= c \tab))))
                  (recur (inc i)) i))
        end (loop [i n]
              (if (and (> i start) (let [c (.charAt s (dec i))] (or (= c \space) (= c \tab))))
                (recur (dec i)) i))]
    (if (and (zero? start) (= end n)) s (.substring s start end))))

(defn compare-code-points
  "Compares two strings by Unicode code point sequence (= UTF-8 byte order)."
  ^long [^String a ^String b]
  (let [na (.length a) nb (.length b) n (min na nb)]
    (loop [i 0]
      (if (< i n)
        (let [ca (.charAt a i) cb (.charAt b i)]
          (if (= ca cb)
            (recur (inc i))
            ;; Surrogates (D800-DFFF) encode code points above FFFF, so they must
            ;; sort after E000-FFFF; shift ranges to restore code point order.
            (let [fix (fn ^long [c]
                        (let [c (long (int c))]
                          (cond (>= c 0xE000) (- c 0x800)
                                (>= c 0xD800) (+ c 0x2000)
                                :else c)))]
              (if (< (fix ca) (fix cb)) -1 1))))
        (Long/compare na nb)))))

(defn code-point-length
  ^long [^String s]
  (.codePointCount s 0 (.length s)))
