package polyquery.json;

/** A JSON number preserved as its literal text (needed for exact ingestion and id echoing). */
public record JsonNumber(String text) {
    /** True if written without fraction or exponent. */
    public boolean isIntegerLiteral() {
        return text.indexOf('.') < 0 && text.indexOf('e') < 0 && text.indexOf('E') < 0;
    }

    public double doubleValue() {
        return Double.parseDouble(text);
    }

    @Override
    public String toString() {
        return text;
    }
}
