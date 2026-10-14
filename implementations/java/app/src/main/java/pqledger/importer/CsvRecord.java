package pqledger.importer;

import java.util.List;

/**
 * One CSV record of a bank file.
 *
 * @param line   the 1-based physical line on which the record starts
 * @param fields the field texts (quotes removed)
 */
public record CsvRecord(int line, List<String> fields) {
}
