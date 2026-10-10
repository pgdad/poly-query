package polyquery.types;

/** Logical type families. {@link #NULL} is the type of the bare {@code NULL} literal. */
public enum TypeKind {
    BOOLEAN,
    INT64,
    DECIMAL,
    FLOAT64,
    STRING,
    DATE,
    TIMESTAMP,
    NULL;

    public boolean isNumeric() {
        return this == INT64 || this == DECIMAL || this == FLOAT64;
    }

    public boolean isTemporal() {
        return this == DATE || this == TIMESTAMP;
    }
}
