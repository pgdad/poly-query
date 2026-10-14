package polyquery.api;

/**
 * An entry of {@link Database#tables()}.
 *
 * @param name     table name
 * @param rowCount number of rows
 */
public record TableInfo(String name, long rowCount) {
}
