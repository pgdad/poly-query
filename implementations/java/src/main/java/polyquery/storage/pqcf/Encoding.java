package polyquery.storage.pqcf;

import polyquery.types.DataType;

/** Column chunk encodings of PQCF v1 (pqcf-v1.md §3). */
public enum Encoding {
    PLAIN,
    /** Dictionary encoding (STRING only). */
    DICT,
    /** Run-length encoding (BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP). */
    RLE;

    /** True if this encoding is defined for columns of {@code type}. */
    public boolean appliesTo(DataType type) {
        return switch (this) {
            case PLAIN -> true;
            case DICT -> type.kind() == polyquery.types.TypeKind.STRING;
            case RLE -> switch (type.kind()) {
                case BOOLEAN, INT64, DECIMAL, DATE, TIMESTAMP -> true;
                default -> false;
            };
        };
    }

    /** Parses an encoding name as written in the metadata; null if unknown. */
    public static Encoding fromName(String name) {
        for (Encoding e : values()) {
            if (e.name().equals(name)) {
                return e;
            }
        }
        return null;
    }
}
