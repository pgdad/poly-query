package polyquery.ingest;

import java.util.List;
import polyquery.storage.ColumnSchema;

/**
 * Parameters of one ingestion.
 *
 * @param schema explicit schema or {@code null} for inference
 * @param header CSV: first record is a header
 * @param delimiter CSV field delimiter
 * @param maxRows maximum number of rows (RESOURCE_LIMIT beyond)
 */
public record IngestOptions(List<ColumnSchema> schema, boolean header, char delimiter, long maxRows) {
}
