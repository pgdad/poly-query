package pqledger.config;

import java.math.BigDecimal;

/**
 * A monthly budget of the budget file.
 *
 * @param category the category
 * @param amount   the monthly budget, scale 2
 */
public record Budget(String category, BigDecimal amount) {
}
