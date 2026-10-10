package polyquery;

import java.util.List;
import polyquery.common.ErrorCode;
import polyquery.ingest.CsvIngest;
import polyquery.ingest.IngestOptions;
import polyquery.ingest.JsonIngest;
import polyquery.storage.ColumnSchema;
import polyquery.storage.Table;
import polyquery.types.DataType;

final class IngestTest {
    private IngestTest() {
    }

    private static IngestOptions infer() {
        return new IngestOptions(null, true, ',', 1_000_000);
    }

    static void testCsvQuotingAndNulls() {
        Table t = CsvIngest.load("t", "﻿id,s\r\n1,\"a,\"\"b\"\"\"\n2,\"\"\n3,\n\n4,\"x\ny\"", infer());
        Assert.eq(4, t.rowCount());
        Assert.eq(DataType.INT64, t.columnType(0));
        Assert.eq("a,\"b\"", t.data().chunk(0, 1).get(0));
        Assert.eq("", t.data().chunk(0, 1).get(1));
        Assert.eq(null, t.data().chunk(0, 1).get(2));
        Assert.eq("x\ny", t.data().chunk(0, 1).get(3));
    }

    static void testCsvInference() {
        Table t = CsvIngest.load("t", "b,i,f,d,ts,s,e\nTRUE,1,1,2024-01-01,2024-01-01,x,\nfalse,-2,2.5,2024-02-29,2024-01-01 10:00:00,1,\n",
                infer());
        List<String> types = t.columns().stream().map(c -> c.type().toString()).toList();
        Assert.eq(List.of("BOOLEAN", "INT64", "FLOAT64", "DATE", "TIMESTAMP", "STRING", "STRING"), types);
        Table big = CsvIngest.load("t", "n\n9223372036854775808\n", infer());
        Assert.eq(DataType.FLOAT64, big.columnType(0));
    }

    static void testCsvErrors() {
        Assert.fails(ErrorCode.INGEST_ERROR, () -> CsvIngest.load("t", "a,b\n1\n", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> CsvIngest.load("t", "a,A\n1,2\n", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> CsvIngest.load("t", "a,\n1,2\n", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> CsvIngest.load("t", "a\n\"open\n", infer()));
        Assert.fails(ErrorCode.RESOURCE_LIMIT,
                () -> CsvIngest.load("t", "a\n1\n2\n3\n", new IngestOptions(null, true, ',', 2)));
    }

    static void testCsvExplicitSchema() {
        List<ColumnSchema> schema = List.of(new ColumnSchema("v", DataType.decimal(4, 1)));
        Table t = CsvIngest.load("t", "v\n123.4\n-0.5\n+7\n", new IngestOptions(schema, true, ',', 100));
        Assert.eq(70L, t.data().chunk(0, 0).get(2));
        Assert.fails(ErrorCode.CONVERSION_ERROR,
                () -> CsvIngest.load("t", "v\n1.25\n", new IngestOptions(schema, true, ',', 100)));
        Assert.fails(ErrorCode.CONVERSION_ERROR,
                () -> CsvIngest.load("t", "v\n1234.5\n", new IngestOptions(schema, true, ',', 100)));
        Assert.fails(ErrorCode.INGEST_ERROR,
                () -> CsvIngest.load("t", "w\n1\n", new IngestOptions(schema, true, ',', 100)));
    }

    static void testJson() {
        Table t = JsonIngest.loadArray("t", "[{\"a\":1,\"b\":\"2024-01-01\"},{\"a\":2.5,\"c\":true}]", infer());
        Assert.eq(List.of("a", "b", "c"), t.columns().stream().map(ColumnSchema::name).toList());
        Assert.eq(DataType.FLOAT64, t.columnType(0));
        Assert.eq(DataType.DATE, t.columnType(1));
        Assert.eq(null, t.data().chunk(0, 2).get(0));
        Table l = JsonIngest.loadLines("t", "{\"x\":null}\n\n{\"x\":null}\n", infer());
        Assert.eq(DataType.STRING, l.columnType(0));
        Assert.eq(2, l.rowCount());
    }

    static void testJsonErrors() {
        Assert.fails(ErrorCode.INGEST_ERROR, () -> JsonIngest.loadArray("t", "[{\"a\":1},{\"a\":\"x\"}]", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> JsonIngest.loadArray("t", "[{\"a\":1},]", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> JsonIngest.loadLines("t", "{\"a\":1,\"a\":2}", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> JsonIngest.loadLines("t", "{\"a\":{\"b\":1}}", infer()));
        Assert.fails(ErrorCode.INGEST_ERROR, () -> JsonIngest.loadLines("t", "{\"a\":NaN}", infer()));
        List<ColumnSchema> schema = List.of(new ColumnSchema("a", DataType.BOOLEAN));
        Assert.fails(ErrorCode.CONVERSION_ERROR,
                () -> JsonIngest.loadLines("t", "{\"a\":\"true\"}", new IngestOptions(schema, true, ',', 10)));
    }
}
