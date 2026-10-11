import unittest

from polyquery import errors, values
from polyquery.datatypes import FLOAT64, INT64, InvalidTypeError, decimal, parse_type


class DecimalTests(unittest.TestCase):
    def test_format(self):
        self.assertEqual(values.format_decimal(-50, 2), "-0.50")
        self.assertEqual(values.format_decimal(12, 0), "12")
        self.assertEqual(values.format_decimal(0, 3), "0.000")
        self.assertEqual(values.format_decimal(123456, 2), "1234.56")

    def test_round_half_away_from_zero(self):
        self.assertEqual(values.rescale(2345, 3, 2), 235)
        self.assertEqual(values.rescale(-2345, 3, 2), -235)
        self.assertEqual(values.rescale(2344, 3, 2), 234)
        self.assertEqual(values.rescale(5, 1, 0), 1)
        self.assertEqual(values.rescale(7, 0, 2), 700)

    def test_parse_exact(self):
        self.assertEqual(values.parse_decimal_text("12.5", 3, exact=True), 12500)
        self.assertEqual(values.parse_decimal_text("-.5", 1, exact=True), -5)
        self.assertEqual(values.parse_decimal_text("+7", 1, exact=True), 70)
        self.assertIsNone(values.parse_decimal_text("1e2", 1, exact=True))
        with self.assertRaises(errors.PolyQueryError):
            values.parse_decimal_text("10.005", 2, exact=True)

    def test_parse_rounding(self):
        self.assertEqual(values.parse_decimal_text("1.005", 2, exact=False), 101)

    def test_float_to_decimal(self):
        self.assertEqual(values.float_to_decimal(2.5, 0), 3)
        self.assertEqual(values.float_to_decimal(-2.5, 0), -3)

    def test_literal_type(self):
        self.assertEqual(values.decimal_literal_type("1.50"), (150, 3, 2))
        self.assertEqual(values.decimal_literal_type("0.05"), (5, 2, 2))
        self.assertEqual(values.decimal_literal_type("00012.5"), (125, 3, 1))
        self.assertEqual(values.decimal_literal_type("3."), (3, 1, 0))
        self.assertEqual(values.decimal_literal_type("1234567890123456789.5"), (12345678901234567895, 20, 1))
        self.assertIsNone(values.decimal_literal_type("1" * 38 + ".5"))


class TemporalTests(unittest.TestCase):
    def test_dates(self):
        self.assertEqual(values.parse_date("1970-01-02"), 1)
        self.assertIsNone(values.parse_date("2023-02-29"))
        self.assertIsNone(values.parse_date("0000-01-01"))
        self.assertEqual(values.format_date(values.parse_date("0099-01-02")), "0099-01-02")

    def test_timestamps(self):
        ts = values.parse_timestamp("2024-02-29T13:14:15.5")
        self.assertEqual(values.format_timestamp(ts), "2024-02-29 13:14:15.500000")
        self.assertEqual(values.format_timestamp(values.parse_timestamp("1969-12-31 23:59:59")), "1969-12-31 23:59:59")
        self.assertIsNone(values.parse_timestamp("2023-01-01 25:00:00"))
        self.assertIsNone(values.parse_timestamp("2024-01-01", allow_date=False))
        self.assertEqual(values.parse_timestamp("2024-01-01"), values.parse_date("2024-01-01") * values.MICROS_PER_DAY)


class TypeNameTests(unittest.TestCase):
    def test_aliases(self):
        self.assertEqual(parse_type("bigint"), INT64)
        self.assertEqual(parse_type("REAL"), FLOAT64)
        self.assertEqual(parse_type("numeric(4, 2)"), decimal(4, 2))
        self.assertEqual(parse_type("DECIMAL").name, "DECIMAL(18,0)")
        self.assertEqual(parse_type("decimal(5)").name, "DECIMAL(5,0)")

    def test_invalid(self):
        for text in ("WIDGET", "DECIMAL(39,2)", "DECIMAL(3,4)", "INT(3)"):
            with self.assertRaises(InvalidTypeError):
                parse_type(text)


if __name__ == "__main__":
    unittest.main()
