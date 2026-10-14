package pqledger;

import static pqledger.Check.eq;

import java.math.BigDecimal;
import java.time.LocalDate;
import java.util.Arrays;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.ColumnType;
import pqledger.output.OutputFormat;
import pqledger.output.Renderer;
import pqledger.output.Tabular;

/** The table, csv and json output formats (spec §7). */
final class OutputTest {
    private OutputTest() {
    }

    private static final Tabular SAMPLE = new Tabular(
            List.of(new Column("month", ColumnType.STRING), new Column("net", ColumnType.decimal(18, 2)),
                    new Column("n", ColumnType.INT64), new Column("x", ColumnType.FLOAT64),
                    new Column("d", ColumnType.DATE), new Column("ok", ColumnType.BOOLEAN)),
            List.of(Arrays.asList("2026-08", new BigDecimal("54.90"), 3L, 1.0 / 3, LocalDate.of(2026, 8, 1), true),
                    Arrays.asList("a,\"b\"", new BigDecimal("-1200.00"), null, -0.0, null, false),
                    Arrays.asList("", BigDecimal.ZERO.setScale(1), 10L, 2.5e-7, LocalDate.of(1, 1, 1), null)));

    static void testTable() {
        eq("""
                month         net   n         x  d           ok
                -------  --------  --  --------  ----------  -----
                2026-08     54.90   3  0.333333  2026-08-01  true
                a,"b"    -1200.00      0.000000              false
                              0.0  10  0.000000  0001-01-01
                (3 rows)
                """, Renderer.render(SAMPLE, OutputFormat.TABLE));
        Tabular one = new Tabular(List.of(new Column("café", ColumnType.STRING)), List.of(List.of("é")));
        eq("café\n----\né\n(1 row)\n", Renderer.render(one, OutputFormat.TABLE));
        Tabular none = new Tabular(List.of(new Column("a", ColumnType.STRING)), List.of());
        eq("a\n-\n(0 rows)\n", Renderer.render(none, OutputFormat.TABLE));
    }

    static void testCsv() {
        eq("month,net,n,x,d,ok\n"
                + "2026-08,54.90,3,0.333333,2026-08-01,true\n"
                + "\"a,\"\"b\"\"\",-1200.00,,0.000000,,false\n"
                + "\"\",0.0,10,0.000000,0001-01-01,\n", Renderer.render(SAMPLE, OutputFormat.CSV));
        Tabular spaces = new Tabular(List.of(new Column("s", ColumnType.STRING)), List.of(List.of(" x"),
                List.of("y "), List.of("a\nb")));
        eq("s\n\" x\"\n\"y \"\n\"a\nb\"\n", Renderer.render(spaces, OutputFormat.CSV));
    }

    static void testJson() {
        eq("""
                {"month":"2026-08","net":"54.90","n":3,"x":0.333333,"d":"2026-08-01","ok":true}
                {"month":"a,\\"b\\"","net":"-1200.00","n":null,"x":0.000000,"d":null,"ok":false}
                {"month":"","net":"0.0","n":10,"x":0.000000,"d":"0001-01-01","ok":null}
                """, Renderer.render(SAMPLE, OutputFormat.JSON));
        Tabular control = new Tabular(List.of(new Column("s", ColumnType.STRING)),
                List.of(List.of("\t\u0001\\é")));
        eq("{\"s\":\"\\t\\u0001\\\\é\"}\n", Renderer.render(control, OutputFormat.JSON));
        eq("", Renderer.render(new Tabular(List.of(new Column("a", ColumnType.STRING)), List.of()),
                OutputFormat.JSON));
    }
}
