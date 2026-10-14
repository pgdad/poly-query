package pqledger.importer;

import java.time.LocalDate;

/**
 * A converted record of a bank export.
 *
 * @param line        physical line on which the record starts
 * @param date        posting date
 * @param description description, trimmed of spaces and tabs
 * @param merchant    normalized description
 * @param cents       amount in cents (negative = money out)
 */
public record BankRecord(int line, LocalDate date, String description, String merchant, long cents) {
}
