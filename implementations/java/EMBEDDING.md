# Embedding PolyQuery in a Java program

The PolyQuery Java engine can be used as a **library**: a Java program creates an engine
instance in its own process, loads data, runs SQL, and reads typed results. Nothing starts a
process or opens a network connection. The public API is the package **`polyquery.api`**
in the module **`polyquery`**, shipped as `build/polyquery.jar`. `bin/polyquery` is the
same engine behind the CLI protocol.

Contents: [Building the library](#building-the-library) ·
[Using it from another project](#using-it-from-another-project) ·
[A complete minimal program](#a-complete-minimal-program) ·
[API reference](#api-reference) · [Value mapping](#value-mapping) · [Errors](#errors) ·
[Resource management](#resource-management) · [Thread safety](#thread-safety) ·
[JVM settings](#jvm-settings) · [Larger examples](#larger-examples)

## Building the library

Requirements: OpenJDK 27 (`java`, `javac` and `jar`, on `PATH` or via `JAVA_HOME`) and
`make`. There are no third-party dependencies.

```sh
cd implementations/java
make build
```

`make build` produces:

| file | contents |
|---|---|
| `build/polyquery.jar` | **the library**: a modular jar, module `polyquery`. It exports only `polyquery.api`; all other packages are internal. `java -jar build/polyquery.jar` is the CLI engine. |
| `build/pqledger.jar` | the example application `pqledger` (module `pqledger`, `requires polyquery`) |
| `build/pq-embed-demo.jar` | the minimal example `examples/embed-demo` |

The jar is compiled with `javac --release 27`, so programs using it need a Java 27 or later
runtime. You can inspect it with:

```
$ jar --describe-module --file build/polyquery.jar | head -3
polyquery jar:file:///…/implementations/java/build/polyquery.jar!/module-info.class
exports polyquery.api
requires java.base mandated
```

## Using it from another project

Your project only needs `build/polyquery.jar`; no source files are copied. Every recipe
below was verified with a separate project in `/tmp` built against
`implementations/java/build/polyquery.jar`. In the examples, `PQ_JAR` is the jar's absolute
path:

```sh
PQ_JAR=/path/to/implementations/java/build/polyquery.jar
```

### Plain `javac`/`java`, as a named module (recommended)

1. Project layout:

   ```
   hello/
     src/main/java/module-info.java
     src/main/java/com/example/hello/Hello.java   (the program below)
   ```

2. `module-info.java` declares the dependency:

   ```java
   module com.example.hello {
       requires polyquery;
   }
   ```

3. Compile and run with the jar on the **module path**:

   ```sh
   javac --module-path "$PQ_JAR" -d out $(find src/main/java -name '*.java')
   mkdir -p data
   java --module-path "$PQ_JAR:out" -m com.example.hello/com.example.hello.Hello data
   ```

As a module, your code can only see `polyquery.api`. The internal packages are strongly
encapsulated.

### Plain `javac`/`java`, on the class path

The same source, without `module-info.java`, also works with the jar on the class path:

```sh
javac -cp "$PQ_JAR" -d out src/com/example/hello/Hello.java
java -cp "$PQ_JAR:out" com.example.hello.Hello data
```

On the class path the module descriptor is ignored, so the internal packages are
technically visible. Use only `polyquery.api`; everything else may change without notice.

A third way also works: a class-path program with the library as a module.

```sh
java --module-path "$PQ_JAR" --add-modules polyquery -cp out com.example.hello.Hello data
```

This is how `bin/pq-embed-demo` runs.

### Maven

The jar is not published to a remote repository. Install it into your **local** Maven
repository once, then depend on it like any other artifact.

1. Install the jar (repeat this after every rebuild of the engine):

   ```sh
   mvn install:install-file -Dfile="$PQ_JAR" \
       -DgroupId=polyquery -DartifactId=polyquery -Dversion=0.1.0 -Dpackaging=jar
   ```

   This copies the jar to `~/.m2/repository/polyquery/polyquery/0.1.0/` and generates a
   minimal POM. The coordinates are your choice; `0.1.0` is the engine version reported by
   `bin/polyquery version`.

2. In your project's `pom.xml`:

   ```xml
   <properties>
     <maven.compiler.release>27</maven.compiler.release>
     <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
   </properties>

   <dependencies>
     <dependency>
       <groupId>polyquery</groupId>
       <artifactId>polyquery</artifactId>
       <version>0.1.0</version>
     </dependency>
   </dependencies>

   <build>
     <plugins>
       <plugin>
         <groupId>org.apache.maven.plugins</groupId>
         <artifactId>maven-compiler-plugin</artifactId>
         <version>3.13.0</version>
       </plugin>
     </plugins>
   </build>
   ```

3. Build with `mvn package`, using `src/main/java/module-info.java` and your sources as
   above. With a `module-info.java` that `requires polyquery`, the compiler plugin puts the
   jar on the module path. Without one, it uses the class path. Both were verified.

4. Run the result, for example:

   ```sh
   java --module-path ~/.m2/repository/polyquery/polyquery/0.1.0/polyquery-0.1.0.jar:target/hello-polyquery-1.0.jar \
        -m com.example.hello/com.example.hello.Hello data
   ```

**Alternative without installing:** a `system`-scoped dependency that points straight at the
built jar. This also works, but Maven deprecates the `system` scope, and the path is
machine-specific:

```xml
<dependency>
  <groupId>polyquery</groupId>
  <artifactId>polyquery</artifactId>
  <version>0.1.0</version>
  <scope>system</scope>
  <systemPath>/path/to/implementations/java/build/polyquery.jar</systemPath>
</dependency>
```

Other build tools work the same way: put `build/polyquery.jar` on the compile and runtime
module path or class path. For Gradle, use `implementation files('/path/to/polyquery.jar')`.
This Gradle recipe was not tested here.

## A complete minimal program

This program creates an instance with a configuration and loads CSV text with an explicit
schema. It runs a query, reads typed values, saves and reopens a PQCF file, lists the
tables, and recovers from an error.

```java
package com.example.hello;

import java.math.BigDecimal;
import java.nio.file.Path;
import java.time.LocalDate;
import java.util.List;
import polyquery.api.Column;
import polyquery.api.Database;
import polyquery.api.DatabaseConfig;
import polyquery.api.DatabaseException;
import polyquery.api.LoadOptions;
import polyquery.api.Result;
import polyquery.api.TableInfo;

public final class Hello {
    public static void main(String[] args) {
        DatabaseConfig config = DatabaseConfig.builder(Path.of(args.length > 0 ? args[0] : "data"))
                .maxQueryMemoryMb(512)
                .threads(2)
                .build();
        try (Database db = Database.create(config)) {
            // CSV text with an explicit schema (without one, 12.50 would be inferred as FLOAT64)
            db.loadText("sales", """
                    day,region,amount
                    2026-09-01,north,12.50
                    2026-09-01,south,7.25
                    2026-09-02,north,30.00
                    """, LoadOptions.csv().withSchema(List.of(
                    Column.of("day", "DATE"), Column.of("region", "STRING"), Column.of("amount", "DECIMAL(10,2)"))));

            Result r = db.query("SELECT region, SUM(amount) AS total, COUNT(*) AS n, MAX(day) AS last_day "
                    + "FROM sales GROUP BY region ORDER BY region");
            System.out.println("columns: " + r.columnNames() + " " + r.columnTypes());
            for (int i = 0; i < r.rowCount(); i++) {
                String region = r.getString(i, 0);
                BigDecimal total = r.getDecimal(i, 1);
                long n = r.getLong(i, 2);
                LocalDate last = r.getDate(i, 3);
                System.out.println(region + " " + total + " " + n + " " + last);
            }

            db.save("sales", "sales.pqcf");          // write a PQCF file into the data directory
            db.open("sales_copy", "sales.pqcf");     // and open it again as another table
            for (TableInfo t : db.tables()) {
                System.out.println("table " + t.name() + " (" + t.rowCount() + " rows)");
            }

            try {
                db.query("SELECT nope FROM sales");
            } catch (DatabaseException e) {          // the instance stays usable
                System.out.println("error: " + e.code() + ": " + e.getMessage());
            }
            System.out.println("rows in sales_copy: " + db.query("SELECT COUNT(*) AS n FROM sales_copy").getLong(0, 0));
        }
    }
}
```

Compiled and run as a named module (see above), with an existing empty directory `data`:

```
$ java --module-path "$PQ_JAR:out" -m com.example.hello/com.example.hello.Hello data
columns: [region, total, n, last_day] [STRING, DECIMAL(18,2), INT64, DATE]
north 42.50 2 2026-09-02
south 7.25 1 2026-09-01
table sales (3 rows)
table sales_copy (3 rows)
error: SEMANTIC_ERROR: unknown column 'nope'
rows in sales_copy: 3
$ ls data
sales.pqcf
```

## API reference

All types are in package `polyquery.api`. Unless stated otherwise:

* `null` arguments throw `NullPointerException`;
* invalid Java-level arguments throw `IllegalArgumentException`;
* engine errors throw `DatabaseException` (see [Errors](#errors)).

### `Database` (final class, `AutoCloseable`)

One engine instance. It holds an in-memory catalog of tables, a data directory for files,
and the SQL engine.

| method | description |
|---|---|
| `static Database create(DatabaseConfig config)` | Creates an instance with an empty catalog. **Throws** `DatabaseException` `NOT_FOUND` if the data directory does not exist; it is not created. |
| `static Database create(Path dataDir)` | Same as `create(DatabaseConfig.of(dataDir))`. |
| `DatabaseConfig config()` | The configuration it was created with. |
| `TableSchema loadFile(String table, String path, LoadOptions options)` | Loads a file of the data directory into a new table (the protocol's `load` with `path`). Returns the new table's schema. |
| `TableSchema loadText(String table, String text, LoadOptions options)` | Loads in-memory CSV/JSON/JSONL text (the protocol's `load` with `data`). |
| `Result query(String sql)` | Same as `query(sql, QueryOptions.DEFAULT)`. |
| `Result query(String sql, QueryOptions options)` | Executes **one** SQL statement and returns its complete result. |
| `TableSchema createTable(String table, List<Column> columns, List<? extends List<?>> rows, boolean replace)` | Creates a table from Java values. This goes beyond the protocol. |
| `TableSchema createTableAs(String table, String sql, QueryOptions options, boolean replace)` | Creates a table holding the result of a query, like `CREATE TABLE … AS SELECT`. This goes beyond the protocol. |
| `long save(String table, String path)` | Writes a table to a PQCF file, relative to the data directory, atomically replacing an existing file. Returns the file size in bytes. |
| `TableSchema open(String table, String path)` | Same as `open(table, path, false)`. |
| `TableSchema open(String table, String path, boolean replace)` | Opens a PQCF file as a table, with the indexes recorded in the file. |
| `void drop(String table)` | Drops a table and its indexes. |
| `List<TableInfo> tables()` | All tables, sorted by name. |
| `TableSchema schema(String table)` | A table's name, row count, columns and indexes. |
| `boolean isClosed()` | True after `close()`. |
| `void close()` | Drops every table and releases the instance. Calling it twice has no effect. |

Details:

* **Paths.** `path` arguments must be relative and must stay inside the data directory.
  Absolute paths and paths that leave it (`../x.csv`) are rejected with `ACCESS_DENIED`,
  as with `--data-dir` in protocol.md §6. A missing file gives `NOT_FOUND`. A missing target
  directory of `save` gives `IO_ERROR`.
* **Table names** must not be empty (`IllegalArgumentException`). An existing name gives
  `ALREADY_EXISTS` unless `replace` is set (via `LoadOptions.withReplace(true)` for loads).
* **`loadFile` / `loadText` errors:** `INGEST_ERROR` for malformed input, with
  `details()` such as `{record=2}`, plus `NOT_FOUND`, `ACCESS_DENIED`, `ALREADY_EXISTS` and
  `RESOURCE_LIMIT` (beyond `maxIngestBytes` / `maxTableRows`). A CSV load with
  `header=false` and no schema, or an invalid delimiter, throws `IllegalArgumentException`.
* **`query` accepts** a query (`SELECT`, `WITH …`, `UNION ALL`), `EXPLAIN …`,
  `CREATE INDEX` and `DROP INDEX`. `EXPLAIN` returns one STRING column `plan`.
  `CREATE/DROP INDEX` return a result with no columns and no rows. There is no
  `CREATE TABLE`, `INSERT` or `UPDATE`; create tables with the load, open,
  `createTable` and `createTableAs` methods.
* **`query` errors:** `PARSE_ERROR` (with `details()` `line` and `column`),
  `SEMANTIC_ERROR`, `TYPE_ERROR`, runtime errors (`NUMERIC_OVERFLOW`, `DIVISION_BY_ZERO`,
  `CONVERSION_ERROR`, `INVALID_ARGUMENT`, `SUBQUERY_CARDINALITY`), `TIMEOUT` and
  `RESOURCE_LIMIT` (memory, `maxRows`, `maxJoinRows`, statement size or nesting depth). A
  second statement after `;` is a `PARSE_ERROR`.
* **`createTable`:** one value per column per row, of the class listed in
  [Value mapping](#value-mapping) or `null`. Some extra classes are accepted:
  * INT64 also takes `Integer`, `Short` and `Byte`;
  * FLOAT64 also takes `Float`;
  * DECIMAL also takes `Long`, `Integer` and `BigInteger`. Values are rounded half away
    from zero to the column's scale, so `2.25` in a `DECIMAL(5,1)` column becomes `2.3`.

  Errors:
  * `IllegalArgumentException` for an empty or duplicate column name, or a row of the wrong
    length;
  * `DatabaseException` `TYPE_ERROR` for a value of the wrong class (`column 'k' of type
    INT64 cannot hold a value of class java.lang.String`);
  * `NUMERIC_OVERFLOW` for a DECIMAL beyond its precision;
  * `INVALID_ARGUMENT` for a non-finite FLOAT64, or a DATE/TIMESTAMP outside
    0001-01-01..9999-12-31;
  * `RESOURCE_LIMIT` and `ALREADY_EXISTS`.
* **`createTableAs`:** result columns of the NULL type (e.g. `SELECT NULL AS z`) become
  STRING columns. Duplicate or empty result column names give `INVALID_REQUEST`. It can
  also throw every error of `query`.
* **`open`** reads the whole file into memory (files over 2 GiB are memory-mapped), so the
  file may be replaced afterwards. Errors: `NOT_FOUND`, `ACCESS_DENIED`, `STORAGE_CORRUPT`,
  `STORAGE_VERSION_UNSUPPORTED`, `ALREADY_EXISTS` and `IO_ERROR`.
* **`drop` and `schema`** throw `NOT_FOUND` for an unknown table.

### `DatabaseConfig` (record) and `DatabaseConfig.Builder`

```java
record DatabaseConfig(Path dataDir, long maxQueryMemoryMb, int threads, long maxIngestBytes,
                      long maxTableRows, long maxJoinRows, boolean testFunctions)
```

| component / builder setter | CLI equivalent | default | constraint |
|---|---|---|---|
| `dataDir` (builder argument) | `--data-dir` | — (required) | not null |
| `maxQueryMemoryMb(long)` | `--max-query-memory-mb` | `DEFAULT_QUERY_MEMORY_MB` = 4096 | ≥ 1 |
| `threads(int)` | `--threads` | `Runtime.availableProcessors()` | ≥ 1 |
| `maxIngestBytes(long)` | `--max-ingest-bytes` | `DEFAULT_INGEST_BYTES` = 4 GiB | ≥ 0 |
| `maxTableRows(long)` | `--max-table-rows` | `DEFAULT_TABLE_ROWS` = 200,000,000 | ≥ 0 |
| `maxJoinRows(long)` | `--max-join-rows` | `DEFAULT_JOIN_ROWS` = 100,000,000 | ≥ 0 |
| `testFunctions(boolean)` | `--enable-test-functions` | `false` | — |

* `DatabaseConfig.builder(Path dataDir)` returns a builder with these defaults, and
  `build()` creates the record.
* `DatabaseConfig.of(Path dataDir)` is the default configuration.
* Out-of-range values throw `IllegalArgumentException` from `build()` or the record
  constructor.
* The effective per-query memory limit is the smaller of `maxQueryMemoryMb` and 70 % of the
  JVM's maximum heap (`-Xmx`).

### `LoadOptions` (record)

```java
record LoadOptions(Format format, List<Column> schema, boolean header, char delimiter, boolean replace)
```

| factory / method | meaning |
|---|---|
| `LoadOptions.csv()` | CSV, header row, `,`, inferred schema, no replace |
| `LoadOptions.json()` | a JSON array of objects, inferred schema |
| `LoadOptions.jsonLines()` | JSON Lines (one object per line), inferred schema |
| `withSchema(List<Column>)` | explicit column names and types (`null`: infer). This is required for CSV without a header. |
| `withHeader(boolean)` | CSV: the first record is a header |
| `withDelimiter(char)` | CSV: one ASCII character other than `"`, CR and LF |
| `withReplace(boolean)` | replace an existing table of the same name |

`LoadOptions.Format` is `CSV`, `JSON` or `JSONL`. Instances are immutable. Schema inference
follows `spec/data-types/ingestion.md`. For example, `12.50` in a CSV file is inferred as
FLOAT64; pass a schema if you need DECIMAL.

### `QueryOptions` (record)

```java
record QueryOptions(int threads, long timeoutMs, long maxRows)
```

| component | meaning | `QueryOptions.DEFAULT` |
|---|---|---|
| `threads` | worker threads for this query, 0–1024 (`MAX_THREADS`); 0 = the instance's `DatabaseConfig.threads()` | 0 |
| `timeoutMs` | time limit in ms (`TIMEOUT` beyond it); 0 = none | 0 |
| `maxRows` | largest allowed result (`RESOURCE_LIMIT: result exceeds max_rows (N)`); -1 = unlimited | -1 |

The `withThreads(int)`, `withTimeoutMs(long)` and `withMaxRows(long)` methods return
modified copies. Out-of-range values throw `IllegalArgumentException`.

### `Result` (final class)

The complete, immutable result of a query. Rows and columns are numbered from 0.

| method | returns |
|---|---|
| `List<Column> columns()` | the columns (name and type) |
| `List<String> columnNames()` | the column names, as reported by the engine |
| `List<ColumnType> columnTypes()` | the column types |
| `int columnCount()`, `int rowCount()` | the sizes |
| `int columnIndex(String name)` | the first column with that name (ASCII case-insensitive), or -1 |
| `Object get(int row, int column)` | the value as its Java class (see [Value mapping](#value-mapping)), or `null` for SQL NULL |
| `boolean isNull(int row, int column)` | true for SQL NULL |
| `Long getLong`, `BigDecimal getDecimal`, `Double getDouble`, `String getString`, `Boolean getBoolean`, `LocalDate getDate`, `LocalDateTime getTimestamp` `(int row, int column)` | the typed value or `null`. They throw `IllegalArgumentException` if the column has another type, e.g. `column 1 ('total') is FLOAT64, not DECIMAL`. |
| `List<Object> row(int row)` | one row (unmodifiable, may contain `null`) |
| `List<List<Object>> rows()` | all rows (an unmodifiable view, converted on access) |

Out-of-range indexes throw `IndexOutOfBoundsException`. A `Result` does not depend on its
`Database`: it stays valid after the instance changes or is closed.

### `Column` (record), `ColumnType` (record), `ColumnType.Kind` (enum)

* `record Column(String name, ColumnType type)` has the factory
  `Column.of(String name, String typeName)`, e.g. `Column.of("amount", "DECIMAL(18,2)")`.
* `record ColumnType(Kind kind, int precision, int scale)`. `precision` and `scale` are
  meaningful only for DECIMAL (precision 1–38, scale 0–precision) and are 0 otherwise.
  * Constants: `BOOLEAN`, `INT64`, `FLOAT64`, `STRING`, `DATE`, `TIMESTAMP`, and
    `MAX_DECIMAL_PRECISION` = 38.
  * `ColumnType.decimal(int precision, int scale)`.
  * `ColumnType.parse(String)` accepts the canonical names and the aliases of types.md,
    case-insensitively: `BIGINT`/`INT`/`INTEGER`, `DOUBLE`/`FLOAT`/`REAL`,
    `VARCHAR`/`TEXT`, `BOOL`, `NUMERIC(p,s)`. A bare `DECIMAL` means `DECIMAL(18,0)`.
    Unknown names throw `IllegalArgumentException`.
  * `typeName()` (also `toString()`) gives the canonical name, e.g. `INT64` or
    `DECIMAL(18,2)`.
  * `isNumeric()` is true for INT64, DECIMAL and FLOAT64.
* `enum Kind { BOOLEAN, INT64, DECIMAL, FLOAT64, STRING, DATE, TIMESTAMP }`.

Result columns whose type is NULL (e.g. `SELECT NULL AS n`) are reported as STRING, and all
their values are `null`.

### `TableSchema` (record), `TableSchema.IndexInfo` (record), `TableInfo` (record)

* `record TableSchema(String name, long rowCount, List<Column> columns, List<IndexInfo> indexes)`
  is returned by `loadFile`, `loadText`, `open`, `createTable`, `createTableAs` and
  `schema`.
* `record IndexInfo(String name, String column, String kind)`, where `kind` is `HASH` or
  `BTREE`. Index names are global within an instance.
* `record TableInfo(String name, long rowCount)` is returned by `tables()`.

### `DatabaseException` (final class, extends `RuntimeException`) and `ErrorCode` (enum)

| member | meaning |
|---|---|
| `ErrorCode code()` | the specification's error code |
| `String getMessage()` | the message |
| `Map<String, Object> details()` | structured details, unmodifiable and often empty, e.g. `{line=1, column=10}` for a `PARSE_ERROR` or `{record=2}` for an `INGEST_ERROR` |
| `String toString()` | `CODE: message` |
| `DatabaseException(ErrorCode, String)`, `DatabaseException(ErrorCode, String, Map)` | public constructors, e.g. for test doubles |

`ErrorCode` has the stable codes of `spec/errors/error-codes.json`: `PARSE_ERROR`,
`SEMANTIC_ERROR`, `TYPE_ERROR`, `NUMERIC_OVERFLOW`, `DIVISION_BY_ZERO`, `CONVERSION_ERROR`,
`INVALID_ARGUMENT`, `SUBQUERY_CARDINALITY`, `INVALID_REQUEST`, `INGEST_ERROR`,
`UNSUPPORTED`, `ACCESS_DENIED`, `NOT_FOUND`, `ALREADY_EXISTS`, `CANCELLED`,
`RESOURCE_LIMIT`, `IO_ERROR`, `STORAGE_CORRUPT`, `STORAGE_VERSION_UNSUPPORTED`,
`INTERNAL_ERROR`, `OVERLOADED`, `SHUTTING_DOWN`, `TIMEOUT`. A few of them, such as
`OVERLOADED` and `SHUTTING_DOWN`, only occur in the HTTP server.

## Value mapping

Values in a `Result`, and the values accepted by `createTable`:

| PolyQuery type | Java class | notes |
|---|---|---|
| `INT64` | `java.lang.Long` | |
| `DECIMAL(p,s)` | `java.math.BigDecimal` | exact; `scale()` is always the column's `s` (`42.50`, not `42.5`) |
| `FLOAT64` | `java.lang.Double` | finite binary64 |
| `STRING` | `java.lang.String` | |
| `BOOLEAN` | `java.lang.Boolean` | |
| `DATE` | `java.time.LocalDate` | 0001-01-01 .. 9999-12-31 |
| `TIMESTAMP` | `java.time.LocalDateTime` | no time zone, microsecond precision; finer nanoseconds given to `createTable` are truncated |
| NULL | `null` | distinguishable from every value; also `isNull(row, col)` |

Verified with
`SELECT 1, 1.5, CAST(1.5 AS FLOAT64), 'x', TRUE, DATE '2026-01-02', TIMESTAMP '2026-01-02 03:04:05.123456', NULL`.
This gives `Long 1`, `BigDecimal 1.5` (type `DECIMAL(2,1)`), `Double 1.5`, `String x`,
`Boolean true`, `LocalDate 2026-01-02`, `LocalDateTime 2026-01-02T03:04:05.123456` and
`null` (type STRING).

## Errors

* **Engine errors** are thrown as the unchecked `DatabaseException`, with `code()` (an
  `ErrorCode`) and `getMessage()`. Unexpected internal failures are reported as
  `INTERNAL_ERROR`. A `StackOverflowError` or `OutOfMemoryError` inside an operation becomes
  `RESOURCE_LIMIT` (`statement too deeply nested`, `out of memory`).
* **After any `DatabaseException` the instance stays usable.** A failed operation leaves the
  catalog unchanged; for example, a failed `loadText` creates no table.
* **Programming errors** are reported with standard Java exceptions, not
  `DatabaseException`:
  * `NullPointerException` for `null` arguments;
  * `IllegalArgumentException` for invalid options or names, and for reading a value with
    the wrong typed getter;
  * `IllegalStateException` for using a closed instance.

```java
try {
    db.query(sql);
} catch (DatabaseException e) {
    switch (e.code()) {
        case PARSE_ERROR, SEMANTIC_ERROR -> System.err.println("bad SQL: " + e.getMessage() + " " + e.details());
        case TIMEOUT -> System.err.println("too slow");
        default -> throw e;
    }
}
```

## Resource management

* `Database` implements `AutoCloseable`. Use try-with-resources, as in the examples.
* **`close()`** drops every table, which releases the memory of the catalog, and marks the
  instance closed. Calling it twice has no effect.
* Operations already running when `close()` is called finish on the catalog version they
  started with.
* **After `close()`**, every operation throws `IllegalStateException("the database is
  closed")`. Only `isClosed()` and `config()` still work.
* `Result` objects stay readable after `close()`, because they hold their own copy of the
  data.
* An instance keeps no files open. PQCF files are read completely by `open` (only files over
  2 GiB are memory-mapped, and those mappings are released by the garbage collector). Files
  in the data directory are only written by `save`, which replaces them atomically.
* Query worker threads come from one shared, process-wide pool of daemon threads. A program
  that forgets to close an instance therefore still exits normally, but its tables stay in
  memory until the instance is unreachable.

## Thread safety

**A `Database` instance is thread-safe.** Any number of threads may call any of its methods
at the same time.

* Each query reads one consistent **snapshot** of the catalog. Tables are immutable.
* Loading, opening, creating, replacing or dropping a table publishes a new catalog version
  atomically. A concurrent query sees either the old or the new table, never a mix.
* This is the same model as concurrent requests in `polyquery serve`.
* `Result`, `DatabaseConfig`, `LoadOptions`, `QueryOptions`, `Column`, `ColumnType`,
  `TableSchema` and `TableInfo` are immutable and can be shared freely.
* `DatabaseConfig.Builder` is not thread-safe; use it on one thread.

**Multiple instances** may exist in one process. Each has its own catalog: a table loaded
into one instance is not visible in another, even with the same data directory. Instances
share only the worker-thread pool. If two instances `save` to the same file, the writes are
atomic and the last one wins.

**Parallelism within a query** is controlled by `DatabaseConfig.threads` and
`QueryOptions.threads`.

## JVM settings

No special JVM flags are required. The embedding API does not use native code, so
`--enable-native-access` is not needed. The optional native kernel library is only used by
the CLI engine.

Recommended settings:

* **Heap:** large tables live on the Java heap. Size it with `-Xmx`. The per-query memory
  limit is capped at 70 % of the maximum heap.
* **Stack depth:** statements are parsed and planned on the **calling thread**. A statement
  nested too deeply for that thread's stack fails with `RESOURCE_LIMIT` (`statement too
  deeply nested`). To accept deeper nesting, run the calls on a thread with a large stack,
  e.g. `new Thread(null, task, "db", 512L << 20)`. pqledger does this. Engine worker
  threads already have 256 MiB stacks.
* **GC:** the launchers use the options in `bin/jvm-options`. They are optional for
  embedding programs:
  * `-XX:+UseParallelGC -XX:-UsePerfData -Xlog:disable`;
  * plus `-Xms4g -Xmn2g` on machines with at least 16 GiB of memory.

  `bin/pqledger` adds `-Xshare:auto` and `$PQLEDGER_JAVA_OPTS`. `bin/pq-embed-demo` runs
  with exactly the `bin/jvm-options` set.

## Larger examples

* **`examples/embed-demo/`** (`src/main/java/demo/EmbedDemo.java`, launcher
  `bin/pq-embed-demo`) is the minimal standalone example of spec/apps/embedding.md §5. It
  uses only `polyquery.api` and works unchanged as a separate project:

  ```
  pq-embed-demo DATA_DIR CSV_FILE SQL
  ```

  It creates an instance on `DATA_DIR` and loads `CSV_FILE` (relative to `DATA_DIR`, with a
  header and an inferred schema) as table `t`. It then runs `SQL` and prints the result as
  CSV. On an engine error it prints `error: CODE: MESSAGE` and exits with status 1.

  ```
  $ bin/pq-embed-demo /tmp/embedtest/demo weather.csv "SELECT city, AVG(temp) AS avg_temp, COUNT(*) AS n FROM t GROUP BY city ORDER BY city"
  city,avg_temp,n
  Oslo,5.250000,2
  Rome,19.250000,1
  $ bin/pq-embed-demo /tmp/embedtest/demo weather.csv "SELECT nope FROM t"
  error: SEMANTIC_ERROR: unknown column 'nope'
  ```

* **`app/`** is the source of **pqledger**, the personal-finance application
  ([APP.md](APP.md)). It is a named module (`app/src/main/java/module-info.java`:
  `requires polyquery;`) that does all of its data access through this API. Places to look:
  * `pqledger/ledger/Ledger.java`: an instance per invocation, `open`/`save` of PQCF
    files, `createTableAs` to rewrite tables, and `[engine]` settings mapped to
    `DatabaseConfig` and `QueryOptions`;
  * `pqledger/commands/ImportCommand.java`: `createTable` from Java values and
    `UNION ALL` appends;
  * `pqledger/ledger/LedgerQueries.java`: the SQL for every report;
  * `pqledger/output/`: rendering a `Result` as a table, CSV or JSON Lines;
  * `pqledger/Main.java`: running on a large-stack thread.
