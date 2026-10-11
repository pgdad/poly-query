(ns polyquery.sql.parser
  "Recursive-descent parser for PolyQuery SQL v1 (spec/sql/grammar.md).
  Produces a plain-map AST; see polyquery.sql.ast for the node shapes. The
  parser covers the whole v1 grammar; later stages decide what is supported."
  (:require [polyquery.errors :as err]
            [polyquery.sql.lexer :as lexer]))

(set! *warn-on-reflection* true)

;; ---------------------------------------------------------------------------
;; Parser state: token vector + mutable cursor

(defrecord State [tokens cursor])

(defn- make-state [tokens] (->State tokens (volatile! 0)))

(defn- peek-tok
  ([st] (peek-tok st 0))
  ([st ^long ahead]
   (let [ts (:tokens st)]
     (nth ts (min (+ (long @(:cursor st)) ahead) (dec (count ts)))))))

(defn- advance! [st]
  (let [t (peek-tok st)]
    (when-not (= :eof (:type t)) (vswap! (:cursor st) inc))
    t))

(defn- pos [tok] {:line (:line tok) :col (:col tok)})

(defn- describe [tok]
  (case (:type tok)
    :eof "end of input"
    :string (str "string '" (:text tok) "'")
    (str "'" (:text tok) "'")))

(defn- fail-at [tok msg]
  (lexer/parse-error! (str msg ", found " (describe tok)) (:line tok) (:col tok)))

(defn- unsupported! [tok what]
  (err/fail! "UNSUPPORTED" (str what " is not supported") {"line" (:line tok) "column" (:col tok)}))

(defn- kw? [tok k] (and (= :keyword (:type tok)) (= k (:text tok))))
(defn- op? [tok o] (and (= :op (:type tok)) (= o (:text tok))))

(defn- at-kw? [st k] (kw? (peek-tok st) k))
(defn- at-op? [st o] (op? (peek-tok st) o))

(defn- accept-kw! [st k] (when (at-kw? st k) (advance! st)))
(defn- accept-op! [st o] (when (at-op? st o) (advance! st)))

(defn- expect-kw! [st k]
  (or (accept-kw! st k) (fail-at (peek-tok st) (str "expected " k))))

(defn- expect-op! [st o]
  (or (accept-op! st o) (fail-at (peek-tok st) (str "expected '" o "'"))))

(defn- ident-token? [tok] (#{:ident :qident} (:type tok)))

(defn- expect-ident! [st what]
  (let [tok (peek-tok st)]
    (if (ident-token? tok)
      (do (advance! st) (:text tok))
      (fail-at tok (str "expected " what)))))

;; ---------------------------------------------------------------------------
;; Expressions

(declare parse-expr parse-query)

(defn- query-start? [st]
  (let [t (peek-tok st)] (or (kw? t "SELECT") (kw? t "WITH"))))

(defn- parse-type-name [st]
  (let [tok (peek-tok st)
        nm (cond
             (ident-token? tok) (:text tok)
             (= :keyword (:type tok)) (:text tok)
             :else (fail-at tok "expected type name"))
        _ (advance! st)
        params (when (accept-op! st "(")
                 (let [num (fn []
                             (let [t (peek-tok st)]
                               (if (and (= :number (:type t)) (re-matches #"[0-9]+" (:text t)))
                                 (do (advance! st)
                                     (try (Long/parseLong (:text t))
                                          (catch NumberFormatException _ Long/MAX_VALUE)))
                                 (fail-at t "expected integer type parameter"))))
                       a (num)
                       b (when (accept-op! st ",") (num))]
                   (expect-op! st ")")
                   (cond-> [a] b (conj b))))]
    {:name nm :params (or params []) :pos (pos tok)}))

(defn- parse-function-call [st name-tok]
  (expect-op! st "(")
  (cond
    (accept-op! st ")")
    {:node :func :name (:text name-tok) :args [] :pos (pos name-tok)}

    (accept-op! st "*")
    (do (expect-op! st ")")
        {:node :func :name (:text name-tok) :star? true :args [] :pos (pos name-tok)})

    :else
    (let [distinct? (boolean (accept-kw! st "DISTINCT"))
          _ (accept-kw! st "ALL")
          args (loop [args [(parse-expr st)]]
                 (if (accept-op! st ",")
                   (recur (conj args (parse-expr st)))
                   args))]
      (expect-op! st ")")
      {:node :func :name (:text name-tok) :distinct? distinct? :args args :pos (pos name-tok)})))

(defn- parse-case [st tok]
  (let [operand (when-not (at-kw? st "WHEN") (parse-expr st))
        whens (loop [whens []]
                (if (accept-kw! st "WHEN")
                  (let [c (parse-expr st)
                        _ (expect-kw! st "THEN")
                        r (parse-expr st)]
                    (recur (conj whens [c r])))
                  whens))
        _ (when (empty? whens) (fail-at (peek-tok st) "expected WHEN"))
        else-expr (when (accept-kw! st "ELSE") (parse-expr st))]
    (expect-kw! st "END")
    {:node :case :operand operand :whens whens :else else-expr :pos (pos tok)}))

(defn- parse-primary [st]
  (let [tok (peek-tok st)]
    (case (:type tok)
      :number (do (advance! st) {:node :literal :kind :number :text (:text tok) :pos (pos tok)})
      :string (do (advance! st) {:node :literal :kind :string :value (:text tok) :pos (pos tok)})
      (:ident :qident)
      (do (advance! st)
          (cond
            (and (= :ident (:type tok)) (at-op? st "("))
            (parse-function-call st tok)

            (at-op? st ".")
            (do (advance! st)
                {:node :column :table (:text tok) :name (expect-ident! st "column name") :pos (pos tok)})

            :else {:node :column :name (:text tok) :pos (pos tok)}))
      :keyword
      (case (:text tok)
        "TRUE" (do (advance! st) {:node :literal :kind :bool :value true :pos (pos tok)})
        "FALSE" (do (advance! st) {:node :literal :kind :bool :value false :pos (pos tok)})
        "NULL" (do (advance! st) {:node :literal :kind :null :pos (pos tok)})
        ("DATE" "TIMESTAMP")
        (do (advance! st)
            (let [s (peek-tok st)]
              (when-not (= :string (:type s)) (fail-at s (str "expected string after " (:text tok))))
              (advance! st)
              {:node :literal :kind (if (= "DATE" (:text tok)) :date :timestamp)
               :value (:text s) :pos (pos tok)}))
        "CAST" (do (advance! st)
                   (expect-op! st "(")
                   (let [arg (parse-expr st)
                         _ (expect-kw! st "AS")
                         tn (parse-type-name st)]
                     (expect-op! st ")")
                     {:node :cast :arg arg :type-name tn :pos (pos tok)}))
        "CASE" (do (advance! st) (parse-case st tok))
        "EXISTS" (do (advance! st)
                     (expect-op! st "(")
                     (let [q (parse-query st)]
                       (expect-op! st ")")
                       {:node :exists :query q :pos (pos tok)}))
        (fail-at tok "expected expression"))
      :op
      (if (= "(" (:text tok))
        (do (advance! st)
            (if (query-start? st)
              (let [q (parse-query st)]
                (expect-op! st ")")
                {:node :subquery :query q :pos (pos tok)})
              (let [e (parse-expr st)]
                (expect-op! st ")")
                (assoc e :parenthesized? true))))
        (fail-at tok "expected expression"))
      (fail-at tok "expected expression"))))

(defn- parse-unary [st]
  (let [tok (peek-tok st)]
    (if (or (op? tok "-") (op? tok "+"))
      (do (advance! st)
          (let [nxt (peek-tok st)]
            ;; fold unary minus into a directly following numeric literal so
            ;; that -9223372036854775808 is representable
            (if (and (op? tok "-") (= :number (:type nxt)))
              (do (advance! st)
                  {:node :literal :kind :number :text (str "-" (:text nxt)) :pos (pos tok)})
              {:node :unary :op (:text tok) :arg (parse-unary st) :pos (pos tok)})))
      (parse-primary st))))

(defn- parse-binary-level
  "Left-associative binary level with operators `ops` over `next-fn`."
  [st ops next-fn]
  (loop [left (next-fn st)]
    (let [tok (peek-tok st)]
      (if (and (= :op (:type tok)) (ops (:text tok)))
        (do (advance! st)
            (recur {:node :binary :op (:text tok) :left left :right (next-fn st) :pos (pos tok)}))
        left))))

(defn- parse-multiplicative [st] (parse-binary-level st #{"*" "/" "%"} parse-unary))
(defn- parse-additive [st] (parse-binary-level st #{"+" "-"} parse-multiplicative))
(defn- parse-concat [st] (parse-binary-level st #{"||"} parse-additive))

(def ^:private comparison-ops {"=" "=" "<>" "<>" "!=" "<>" "<" "<" "<=" "<=" ">" ">" ">=" ">="})

(defn- parse-predicate [st]
  (let [left (parse-concat st)
        tok (peek-tok st)]
    (cond
      (and (= :op (:type tok)) (comparison-ops (:text tok)))
      (do (advance! st)
          {:node :binary :op (comparison-ops (:text tok)) :left left :right (parse-concat st) :pos (pos tok)})

      (kw? tok "IS")
      (do (advance! st)
          (let [not? (boolean (accept-kw! st "NOT"))]
            (expect-kw! st "NULL")
            {:node :is-null :not? not? :arg left :pos (pos tok)}))

      (or (kw? tok "NOT") (kw? tok "BETWEEN") (kw? tok "IN") (kw? tok "LIKE"))
      (let [not? (boolean (accept-kw! st "NOT"))
            op-tok (peek-tok st)]
        (cond
          (accept-kw! st "BETWEEN")
          (let [lo (parse-concat st)
                _ (expect-kw! st "AND")
                hi (parse-concat st)]
            {:node :between :not? not? :arg left :low lo :high hi :pos (pos op-tok)})

          (accept-kw! st "IN")
          (do (expect-op! st "(")
              (if (query-start? st)
                (let [q (parse-query st)]
                  (expect-op! st ")")
                  {:node :in-query :not? not? :arg left :query q :pos (pos op-tok)})
                (let [items (loop [items [(parse-expr st)]]
                              (if (accept-op! st ",")
                                (recur (conj items (parse-expr st)))
                                items))]
                  (expect-op! st ")")
                  {:node :in-list :not? not? :arg left :items items :pos (pos op-tok)})))

          (accept-kw! st "LIKE")
          {:node :like :not? not? :arg left :pattern (parse-concat st) :pos (pos op-tok)}

          :else (fail-at op-tok "expected BETWEEN, IN or LIKE")))

      :else left)))

(defn- parse-not [st]
  (let [tok (peek-tok st)]
    (if (kw? tok "NOT")
      (do (advance! st) {:node :not :arg (parse-not st) :pos (pos tok)})
      (parse-predicate st))))

(defn- parse-and [st]
  (loop [left (parse-not st)]
    (let [tok (peek-tok st)]
      (if (kw? tok "AND")
        (do (advance! st)
            (recur {:node :binary :op "AND" :left left :right (parse-not st) :pos (pos tok)}))
        left))))

(defn parse-expr [st]
  (loop [left (parse-and st)]
    (let [tok (peek-tok st)]
      (if (kw? tok "OR")
        (do (advance! st)
            (recur {:node :binary :op "OR" :left left :right (parse-and st) :pos (pos tok)}))
        left))))

;; ---------------------------------------------------------------------------
;; Queries

(defn- parse-alias
  "Optional [AS] alias."
  [st]
  (if (accept-kw! st "AS")
    (expect-ident! st "alias")
    (when (ident-token? (peek-tok st))
      (:text (advance! st)))))

(def ^:private future-join-words
  "Keywords reserved only for future join syntax (grammar.md §1). After an
  explicit AS they cannot start any construct, so they are accepted there as
  output column names (e.g. `SELECT x AS full`)."
  #{"FULL" "RIGHT"})

(defn- parse-output-alias
  "Optional [AS] alias of a select item."
  [st]
  (let [tok (peek-tok st 1)]
    (if (and (at-kw? st "AS") (= :keyword (:type tok)) (future-join-words (:text tok)))
      (do (advance! st) (advance! st) (:raw tok))
      (parse-alias st))))

(defn- parse-select-item [st]
  (let [tok (peek-tok st)]
    (cond
      (op? tok "*")
      (do (advance! st) {:kind :star :pos (pos tok)})

      (and (ident-token? tok) (op? (peek-tok st 1) ".") (op? (peek-tok st 2) "*"))
      (do (advance! st) (advance! st) (advance! st)
          {:kind :star :table (:text tok) :pos (pos tok)})

      :else
      {:kind :expr :expr (parse-expr st) :alias (parse-output-alias st) :pos (pos tok)})))

(declare parse-from-item)

(defn- parse-table-ref [st]
  (let [tok (peek-tok st)]
    (cond
      (op? tok "(")
      (do (advance! st)
          (if (query-start? st)
            (let [q (parse-query st)
                  _ (expect-op! st ")")
                  alias (parse-alias st)]
              (when-not alias (fail-at (peek-tok st) "derived table requires an alias"))
              {:node :derived :query q :alias alias :pos (pos tok)})
            (let [f (parse-from-item st)]
              (expect-op! st ")")
              f)))

      (ident-token? tok)
      (do (advance! st)
          {:node :table :name (:text tok) :alias (parse-alias st) :pos (pos tok)})

      :else (fail-at tok "expected table name"))))

(defn parse-from-item [st]
  (loop [left (parse-table-ref st)]
    (let [tok (peek-tok st)]
      (cond
        (op? tok ",")
        (do (advance! st)
            (recur {:node :join :kind :cross :left left :right (parse-table-ref st) :pos (pos tok)}))

        (kw? tok "CROSS")
        (do (advance! st) (expect-kw! st "JOIN")
            (recur {:node :join :kind :cross :left left :right (parse-table-ref st) :pos (pos tok)}))

        (or (kw? tok "JOIN") (kw? tok "INNER"))
        (do (advance! st)
            (when (kw? tok "INNER") (expect-kw! st "JOIN"))
            (let [right (parse-table-ref st)]
              (expect-kw! st "ON")
              (recur {:node :join :kind :inner :left left :right right :on (parse-expr st) :pos (pos tok)})))

        (kw? tok "LEFT")
        (do (advance! st) (accept-kw! st "OUTER") (expect-kw! st "JOIN")
            (let [right (parse-table-ref st)]
              (expect-kw! st "ON")
              (recur {:node :join :kind :left :left left :right right :on (parse-expr st) :pos (pos tok)})))

        (or (kw? tok "RIGHT") (kw? tok "FULL"))
        (unsupported! tok (str (:text tok) " JOIN"))

        :else left))))

(defn- parse-select-core [st]
  (let [tok (expect-kw! st "SELECT")
        distinct? (cond (accept-kw! st "DISTINCT") true
                        (accept-kw! st "ALL") false
                        :else false)
        items (loop [items [(parse-select-item st)]]
                (if (accept-op! st ",")
                  (recur (conj items (parse-select-item st)))
                  items))
        from (when (accept-kw! st "FROM") (parse-from-item st))
        where (when (accept-kw! st "WHERE") (parse-expr st))
        group-by (when (accept-kw! st "GROUP")
                   (expect-kw! st "BY")
                   (loop [gs [(parse-expr st)]]
                     (if (accept-op! st ",") (recur (conj gs (parse-expr st))) gs)))
        having (when (accept-kw! st "HAVING") (parse-expr st))]
    {:distinct? distinct? :items items :from from :where where
     :group-by group-by :having having :pos (pos tok)}))

(defn- parse-order-by [st]
  (loop [items []]
    (let [e (parse-expr st)
          dir (cond (accept-kw! st "ASC") :asc
                    (accept-kw! st "DESC") :desc
                    :else :asc)
          nulls (when (accept-kw! st "NULLS")
                  (cond (accept-kw! st "FIRST") :first
                        (accept-kw! st "LAST") :last
                        :else (fail-at (peek-tok st) "expected FIRST or LAST")))
          items (conj items {:expr e :desc? (= dir :desc) :nulls nulls})]
      (if (accept-op! st ",") (recur items) items))))

(defn- parse-cte [st]
  (let [tok (peek-tok st)
        nm (expect-ident! st "CTE name")
        cols (when (accept-op! st "(")
               (let [cs (loop [cs [(expect-ident! st "column name")]]
                          (if (accept-op! st ",") (recur (conj cs (expect-ident! st "column name"))) cs))]
                 (expect-op! st ")")
                 cs))
        _ (expect-kw! st "AS")
        _ (expect-op! st "(")
        q (parse-query st)]
    (expect-op! st ")")
    {:name nm :columns cols :query q :pos (pos tok)}))

(defn- parse-union-all-branches
  "The select cores following the first one in `core { UNION ALL core }`
  (CR-1). UNION without ALL (incl. UNION DISTINCT) is reserved: UNSUPPORTED.
  Branches are plain select cores, so a parenthesized branch or a branch
  with its own ORDER BY/LIMIT is a PARSE_ERROR (left to the callers'
  end-of-query checks)."
  [st]
  (loop [branches []]
    (if-let [tok (accept-kw! st "UNION")]
      (if (accept-kw! st "ALL")
        (recur (conj branches (parse-select-core st)))
        (unsupported! tok "UNION without ALL"))
      branches)))

(defn parse-query [st]
  (let [tok (peek-tok st)
        with (when (accept-kw! st "WITH")
               (loop [ctes [(parse-cte st)]]
                 (if (accept-op! st ",") (recur (conj ctes (parse-cte st))) ctes)))
        core (parse-select-core st)
        more (parse-union-all-branches st)
        order-by (when (accept-kw! st "ORDER")
                   (expect-kw! st "BY")
                   (parse-order-by st))
        [limit offset] (cond
                         (accept-kw! st "LIMIT")
                         (let [l (parse-expr st)]
                           [l (when (accept-kw! st "OFFSET") (parse-expr st))])
                         (accept-kw! st "OFFSET")
                         (let [o (parse-expr st)]
                           [(when (accept-kw! st "LIMIT") (parse-expr st)) o])
                         :else nil)]
    {:node :query :with with :select core :union-all more
     :order-by order-by :limit limit :offset offset :pos (pos tok)}))

;; ---------------------------------------------------------------------------
;; Statements

(defn- parse-create-index [st tok]
  (expect-kw! st "INDEX")
  (let [if-not-exists? (when (accept-kw! st "IF") (expect-kw! st "NOT") (expect-kw! st "EXISTS") true)
        nm (expect-ident! st "index name")
        _ (expect-kw! st "ON")
        tbl (expect-ident! st "table name")
        _ (expect-op! st "(")
        col (expect-ident! st "column name")
        _ (expect-op! st ")")
        kind (when (accept-kw! st "USING")
               (let [k (peek-tok st)]
                 (if (and (= :ident (:type k)) (#{"HASH" "BTREE"} (.toUpperCase ^String (:text k))))
                   (do (advance! st) (keyword (.toLowerCase ^String (:text k))))
                   (fail-at k "expected HASH or BTREE"))))]
    {:node :create-index :name nm :table tbl :column col :kind (or kind :btree)
     :if-not-exists? (boolean if-not-exists?) :pos (pos tok)}))

(defn- parse-drop-index [st tok]
  (expect-kw! st "INDEX")
  (let [if-exists? (when (accept-kw! st "IF") (expect-kw! st "EXISTS") true)]
    {:node :drop-index :name (expect-ident! st "index name") :if-exists? (boolean if-exists?)
     :pos (pos tok)}))

(defn parse-statement
  "Parses one SQL statement (with an optional trailing ';')."
  [^String sql]
  (let [st (make-state (lexer/tokenize sql))
        tok (peek-tok st)
        stmt (cond
               (kw? tok "EXPLAIN") (do (advance! st) {:node :explain :query (parse-query st) :pos (pos tok)})
               (kw? tok "CREATE") (do (advance! st) (parse-create-index st tok))
               (kw? tok "DROP") (do (advance! st) (parse-drop-index st tok))
               (query-start? st) {:node :select :query (parse-query st) :pos (pos tok)}
               :else (fail-at tok "expected SELECT"))]
    (accept-op! st ";")
    (let [t (peek-tok st)]
      (when-not (= :eof (:type t))
        (fail-at t "unexpected token after end of statement")))
    stmt))
