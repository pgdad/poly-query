;; AOT-compiles a program that uses the engine as a library (pqledger, the
;; embedding example): clojure -M compile-client.clj NAMESPACE OUTPUT-DIR,
;; run in the program's directory. The engine's own classes come from
;; target/polyquery.jar on the class path and are not compiled again.
(let [[ns-name out] *command-line-args*]
  (binding [*compile-path* out
            *compiler-options* {:direct-linking true}
            *warn-on-reflection* true]
    (compile (symbol ns-name))))
