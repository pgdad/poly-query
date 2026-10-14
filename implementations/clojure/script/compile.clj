;; AOT-compiles the engine into target/classes (invoked by `make build`):
;; the CLI (polyquery.main) and the embedding API (polyquery.api).
(binding [*compile-path* "target/classes"
          *compiler-options* {:direct-linking true}
          *warn-on-reflection* true]
  (compile 'polyquery.main)
  (compile 'polyquery.api))
