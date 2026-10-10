package polyquery.json;

/** Malformed JSON text. */
public class JsonException extends Exception {
    public JsonException(String message) {
        super(message, null, false, false);
    }
}
