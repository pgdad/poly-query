import unittest

from polyquery import errors
from polyquery.sql import ast
from polyquery.sql.lexer import TokenKind, tokenize
from polyquery.sql.parser import parse


def query(sql: str) -> ast.Query:
    stmt = parse(sql)
    assert isinstance(stmt, ast.QueryStatement)
    return stmt.query


class LexerTests(unittest.TestCase):
    def test_tokens_and_positions(self):
        toks = tokenize("SELECT a,\n  'it''s' -- c\n /* x */ \"Q\"\"x\" <> 1.5e3")
        kinds = [(t.kind, t.value) for t in toks]
        self.assertEqual(
            kinds,
            [
                (TokenKind.KEYWORD, "SELECT"),
                (TokenKind.IDENT, "a"),
                (TokenKind.OP, ","),
                (TokenKind.STRING, "it's"),
                (TokenKind.IDENT, 'Q"x'),
                (TokenKind.OP, "<>"),
                (TokenKind.NUMBER, "1.5e3"),
                (TokenKind.EOF, ""),
            ],
        )
        self.assertEqual((toks[3].line, toks[3].column), (2, 3))

    def test_errors(self):
        for sql in ("SELECT 'x", "SELECT /* x", "SELECT 1e", "SELECT #", 'SELECT "x'):
            with self.assertRaises(errors.PolyQueryError) as cm:
                tokenize(sql)
            self.assertEqual(cm.exception.code, errors.PARSE_ERROR)


class ParserTests(unittest.TestCase):
    def test_precedence(self):
        q = query("SELECT 2 + 3 * 4, NOT a = b AND c OR d")
        first = q.body.items[0].expr
        self.assertIsInstance(first, ast.BinaryOp)
        self.assertEqual(first.op, "+")
        self.assertEqual(first.right.op, "*")
        second = q.body.items[1].expr
        self.assertEqual(second.op, "OR")
        self.assertEqual(second.left.op, "AND")
        self.assertIsInstance(second.left.left, ast.UnaryOp)

    def test_negative_literal_folding(self):
        q = query("SELECT -9223372036854775808, - - 1, -(2)")
        self.assertEqual(q.body.items[0].expr.text, "-9223372036854775808")
        self.assertIsInstance(q.body.items[1].expr, ast.UnaryOp)
        self.assertIsInstance(q.body.items[2].expr, ast.UnaryOp)

    def test_clauses(self):
        q = query("SELECT p.*, x AS y, z w FROM t p WHERE a IS NOT NULL ORDER BY 1 DESC NULLS LAST, y OFFSET 2 LIMIT 3;")
        self.assertTrue(q.body.items[0].is_star)
        self.assertEqual(q.body.items[0].star_qualifier, "p")
        self.assertEqual([i.alias for i in q.body.items[1:]], ["y", "w"])
        self.assertEqual(q.body.from_.alias, "p")
        self.assertTrue(q.order_by[0].descending)
        self.assertFalse(q.order_by[0].nulls_first)
        self.assertIsNotNone(q.limit)
        self.assertIsNotNone(q.offset)

    def test_full_grammar_parses(self):
        parse("WITH c AS (SELECT 1 AS x) SELECT DISTINCT x FROM c JOIN d ON c.x = d.x GROUP BY x HAVING COUNT(*) > 1")
        parse("SELECT CASE WHEN a BETWEEN 1 AND 2 THEN 'x' ELSE 'y' END, b IN (1, 2), c LIKE 'a%' FROM t")
        parse("CREATE INDEX IF NOT EXISTS i ON t (c) USING HASH")
        parse("DROP INDEX IF EXISTS i")
        parse("EXPLAIN SELECT * FROM t")

    def test_syntax_errors(self):
        for sql in ("SELECT 1 = 1 = 1", "SELECT 1; SELECT 2", "SELEC 1", "SELECT", "SELECT COUNT(*, a) FROM t",
                    "SELECT a FROM t LIMIT", "SELECT a < b IS NULL"):
            with self.assertRaises(errors.PolyQueryError) as cm:
                parse(sql)
            self.assertEqual(cm.exception.code, errors.PARSE_ERROR, sql)

    def test_reserved_future_syntax(self):
        for sql in ("SELECT 1 UNION SELECT 2", "SELECT * FROM a FULL JOIN b ON a.x = b.x"):
            with self.assertRaises(errors.PolyQueryError) as cm:
                parse(sql)
            self.assertEqual(cm.exception.code, errors.UNSUPPORTED)


if __name__ == "__main__":
    unittest.main()
