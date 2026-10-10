;; AOT-compiles the engine into target/classes (invoked by `make build`).
(binding [*compile-path* "target/classes"
          *compiler-options* {:direct-linking true}
          *warn-on-reflection* true]
  (compile 'polyquery.main))
