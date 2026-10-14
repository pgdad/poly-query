/**
 * The PolyQuery engine. Only the embedding API, {@code polyquery.api}, is exported; every other
 * package is internal. {@code java -jar polyquery.jar} runs the command-line engine
 * ({@code bin/polyquery}).
 */
module polyquery {
    exports polyquery.api;
}
