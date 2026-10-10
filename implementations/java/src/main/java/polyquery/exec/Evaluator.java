package polyquery.exec;

/** A compiled scalar expression evaluated against one input row. */
@FunctionalInterface
public interface Evaluator {
    Object eval(Object[] row);
}
