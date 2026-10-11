(ns polyquery.sql.lexer
  "SQL tokenizer (spec/sql/grammar.md §1).

  Tokens are maps {:type :text :line :col} where :type is one of
  :keyword (text upper-cased, original spelling in :raw), :ident (unquoted identifier), :qident (quoted
  identifier, text unescaped), :number, :string (text unescaped), :op
  (operator/punctuation) or :eof."
  (:require [polyquery.errors :as err]
            [polyquery.util.text :as text]))

(set! *warn-on-reflection* true)

(def reserved
  #{"ALL" "AND" "AS" "ASC" "BETWEEN" "BY" "CASE" "CAST" "CREATE" "CROSS" "DATE" "DESC"
    "DISTINCT" "DROP" "ELSE" "END" "EXISTS" "EXPLAIN" "FALSE" "FIRST" "FROM" "FULL" "GROUP"
    "HAVING" "IF" "IN" "INDEX" "INNER" "IS" "JOIN" "LAST" "LEFT" "LIKE" "LIMIT" "NOT" "NULL"
    "NULLS" "OFFSET" "ON" "OR" "ORDER" "OUTER" "RIGHT" "SELECT" "THEN" "TIMESTAMP" "TRUE"
    "UNION" "USING" "WHEN" "WHERE" "WITH"})

(defn parse-error!
  [msg line col]
  (err/fail! "PARSE_ERROR" (str msg " at line " line ", column " col) {"line" line "column" col}))

(defn- ident-start? [c]
  (or (and (>= (int c) (int \a)) (<= (int c) (int \z)))
      (and (>= (int c) (int \A)) (<= (int c) (int \Z)))
      (= c \_)))

(defn- digit? [c] (and (>= (int c) (int \0)) (<= (int c) (int \9))))

(defn- ident-char? [c] (or (ident-start? c) (digit? c)))

(defn tokenize
  "Returns a vector of tokens ending with an :eof token."
  [^String sql]
  (let [n (.length sql)
        tokens (transient [])
        ;; line/column bookkeeping
        line-starts (loop [i 0 acc [0]]
                      (if (< i n)
                        (recur (inc i) (if (= (.charAt sql i) \newline) (conj acc (inc i)) acc))
                        acc))
        pos->lc (fn [^long p]
                  (let [li (long (loop [lo 0 hi (dec (count line-starts))]
                                   (if (< lo hi)
                                     (let [mid (quot (+ lo hi 1) 2)]
                                       (if (<= (long (nth line-starts mid)) p) (recur mid hi) (recur lo (dec mid))))
                                     lo)))]
                    [(inc li) (inc (- p (long (nth line-starts li))))]))
        fail (fn [msg p] (let [[l c] (pos->lc p)] (parse-error! msg l c)))
        ch (fn [^long i] (when (< i n) (.charAt sql i)))
        emit (fn
               ([type text start]
                (let [[l c] (pos->lc start)]
                  (conj! tokens {:type type :text text :line l :col c})))
               ([type text start raw]
                (let [[l c] (pos->lc start)]
                  (conj! tokens {:type type :text text :line l :col c :raw raw}))))]
    (loop [i 0]
      (if (>= i n)
        (let [[l c] (pos->lc n)]
          (persistent! (conj! tokens {:type :eof :text "" :line l :col c})))
        (let [c (.charAt sql i)]
          (cond
            (or (= c \space) (= c \tab) (= c \newline) (= c \return)) (recur (inc i))

            (and (= c \-) (= (ch (inc i)) \-))
            (recur (long (loop [j (+ i 2)] (if (and (< j n) (not= (.charAt sql j) \newline)) (recur (inc j)) j))))

            (and (= c \/) (= (ch (inc i)) \*))
            (let [end (.indexOf sql "*/" (int (+ i 2)))]
              (when (neg? end) (fail "unterminated block comment" i))
              (recur (long (+ end 2))))

            (ident-start? c)
            (let [j (loop [j (inc i)] (if (and (< j n) (ident-char? (.charAt sql j))) (recur (inc j)) j))
                  word (subs sql i j)
                  up (text/ascii-upper word)]
              (if (reserved up)
                (emit :keyword up i word)
                (emit :ident word i))
              (recur (long j)))

            (= c \")
            (let [sb (StringBuilder.)
                  j (loop [j (inc i)]
                      (cond
                        (>= j n) (fail "unterminated quoted identifier" i)
                        (= (.charAt sql j) \") (if (= (ch (inc j)) \")
                                                 (do (.append sb \") (recur (+ j 2)))
                                                 (inc j))
                        :else (do (.append sb (.charAt sql j)) (recur (inc j)))))]
              (when (zero? (.length sb)) (fail "empty quoted identifier" i))
              (emit :qident (.toString sb) i)
              (recur (long j)))

            (= c \')
            (let [sb (StringBuilder.)
                  j (loop [j (inc i)]
                      (cond
                        (>= j n) (fail "unterminated string literal" i)
                        (= (.charAt sql j) \') (if (= (ch (inc j)) \')
                                                 (do (.append sb \') (recur (+ j 2)))
                                                 (inc j))
                        :else (do (.append sb (.charAt sql j)) (recur (inc j)))))]
              (emit :string (.toString sb) i)
              (recur (long j)))

            (or (digit? c) (and (= c \.) (some-> (ch (inc i)) digit?)))
            (let [digits (fn [^long j] (loop [j j] (if (and (< j n) (digit? (.charAt sql j))) (recur (inc j)) j)))
                  j (long (digits i))
                  j (long (if (= (ch j) \.) (digits (inc j)) j))
                  j (long (if (and (#{\e \E} (ch j))
                                   (or (some-> (ch (inc j)) digit?)
                                       (and (#{\+ \-} (ch (inc j))) (some-> (ch (+ j 2)) digit?))))
                            (digits (+ j 2))
                            j))]
              (when (and (< j n) (or (ident-char? (.charAt sql j)) (= (.charAt sql j) \.)))
                (fail "malformed numeric literal" i))
              (emit :number (subs sql i j) i)
              (recur (long j)))

            :else
            (let [two (when (< (inc i) n) (subs sql i (+ i 2)))]
              (cond
                (#{"<=" ">=" "<>" "!=" "||"} two) (do (emit :op two i) (recur (+ i 2)))
                (#{\+ \- \* \/ \% \= \< \> \( \) \, \. \;} c) (do (emit :op (str c) i) (recur (inc i)))
                :else (fail (str "unexpected character '" c "'") i)))))))))
