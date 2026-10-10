package polyquery.sql.ast;

/** Top-level SQL statements. */
public sealed interface Statement {
    SourcePos pos();

    record QueryStatement(SourcePos pos, Query query) implements Statement {
    }

    record Explain(SourcePos pos, Query query) implements Statement {
    }

    record CreateIndex(SourcePos pos, String name, boolean ifNotExists, String table, String column,
                       String kind) implements Statement {
    }

    record DropIndex(SourcePos pos, String name, boolean ifExists) implements Statement {
    }
}
