package polyquery;

import polyquery.common.ErrorCode;
import polyquery.types.Casts;
import polyquery.types.DataType;
import polyquery.types.DateTimes;
import polyquery.types.Decimals;
import polyquery.types.TextParsers;
import polyquery.types.Values;

final class TypesTest {
    private TypesTest() {
    }

    static void testTypeNames() {
        Assert.eq("DECIMAL(18,0)", DataType.parse("numeric").toString());
        Assert.eq("DECIMAL(7,0)", DataType.parse("decimal(7)").toString());
        Assert.eq("DECIMAL(10,2)", DataType.parse("NUMERIC(10, 2)").toString());
        Assert.eq(DataType.INT64, DataType.parse("bigint"));
        Assert.eq(DataType.STRING, DataType.parse("text"));
        Assert.eq("STRING", DataType.NULL.toString());
        Assert.fails(ErrorCode.SEMANTIC_ERROR, () -> DataType.parse("DECIMAL(39,2)"));
    }

    static void testDecimalArithmetic() {
        Assert.eq(375L, Decimals.add(125, 2, 25, 1, 2));
        Assert.eq("-0.05", Decimals.toString(-5, 2));
        Assert.eq("12", Decimals.toString(12, 0));
        Assert.eq("0.000", Decimals.toString(0, 3));
        Assert.eq(235L, Decimals.rescale(2345, 3, 2));
        Assert.eq(-235L, Decimals.rescale(-2345, 3, 2));
        Assert.eq(0, Decimals.compare(150, 2, 15, 1));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> Decimals.add(999_999_999_999_999_999L, 1, 1, 1, 1));
        // Exact intermediate: 10^17 (scale 0) rescaled to scale 1 then minus 1 fits 18 digits.
        Assert.eq(999_999_999_999_999_999L, Decimals.subtract(100_000_000_000_000_000L, 0, 1, 1, 1));
    }

    static void testDates() {
        Assert.eq(0, (int) DateTimes.parseDate("1970-01-01"));
        Assert.eq(null, DateTimes.parseDate("2023-02-29"));
        Assert.eq(null, DateTimes.parseDate("0000-01-01"));
        Assert.eq("0001-01-01", DateTimes.formatDate(DateTimes.MIN_DAY));
        long ts = DateTimes.parseTimestamp("2024-02-29T13:14:15.5", false);
        Assert.eq("2024-02-29 13:14:15.500000", DateTimes.formatTimestamp(ts));
        Assert.eq(null, DateTimes.parseTimestamp("2024-01-01 24:00:00", false));
        Assert.eq(null, DateTimes.parseTimestamp("2024-01-01", false));
        Assert.eq("9999-12-31 23:59:59.999999",
                DateTimes.formatTimestamp(DateTimes.parseTimestamp("9999-12-31 23:59:59.999999", false)));
    }

    static void testTextParsers() {
        Assert.eq(-7L, TextParsers.parseInt64("-7"));
        Assert.eq(null, TextParsers.parseInt64("1.0"));
        Assert.eq(null, TextParsers.parseFloat64("NaN"));
        Assert.eq(null, TextParsers.parseFloat64("1e"));
        Assert.eq(0.5, TextParsers.parseFloat64(".5"));
        Assert.eq(7000L, TextParsers.parseDecimal("+7", 4, 3, false));
        Assert.eq(101L, TextParsers.parseDecimal("1.005", 4, 2, true));
        try {
            TextParsers.parseDecimal("1.50", 4, 1, false);
            throw new AssertionError("trailing zeros beyond scale must be rejected");
        } catch (ArithmeticException expected) {
            // ok
        }
    }

    static void testCasts() {
        Assert.eq(-3L, Casts.cast(-375L, DataType.decimal(3, 2), DataType.INT64));
        Assert.eq(235L, Casts.cast(2345L, DataType.decimal(4, 3), DataType.decimal(5, 2)));
        Assert.eq(3L, Casts.cast(2.5, DataType.FLOAT64, DataType.decimal(3, 0)));
        Assert.eq("1.50", Casts.cast(150L, DataType.decimal(3, 2), DataType.STRING));
        Assert.fails(ErrorCode.CONVERSION_ERROR, () -> Casts.cast("yes", DataType.STRING, DataType.BOOLEAN));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> Casts.cast(1000L, DataType.INT64, DataType.decimal(3, 0)));
        Assert.fails(ErrorCode.NUMERIC_OVERFLOW, () -> Casts.cast(1e19, DataType.FLOAT64, DataType.INT64));
        Assert.check(!Casts.allowed(DataType.DATE, DataType.INT64), "DATE→INT64 not allowed");
    }

    static void testStringOrderIsCodePoint() {
        Assert.check(Values.compareStrings("B", "a") < 0, "uppercase first");
        // U+FF5E (BMP) sorts before U+1F600 (supplementary) by code point.
        Assert.check(Values.compareStrings("～", "😀") < 0, "code point order");
    }
}
