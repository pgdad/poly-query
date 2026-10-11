package polyquery.sql.analyzer;

import static polyquery.sql.analyzer.TypeCoercion.typeError;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.ConstantEvaluator;
import polyquery.plan.BoundExpr;
import polyquery.plan.BoundExprs;
import polyquery.types.DataType;
import polyquery.types.TypeKind;

/**
 * Type checking of scalar function calls (functions.md §1). Produces {@link BoundExpr.Function}
 * nodes with canonical names and arguments already coerced to the types the runtime expects.
 */
final class ScalarFunctionBinder {
    static final Set<String> TRUNC_UNITS = Set.of("year", "month", "day", "hour", "minute");

    private ScalarFunctionBinder() {
    }

    /** Binds a call whose arity has already been checked. */
    static BoundExpr bind(String name, List<BoundExpr> args) {
        return switch (name) {
            case "ABS" -> new BoundExpr.Function("ABS", args, numeric(name, args.get(0)));
            case "ROUND" -> round(args);
            case "FLOOR", "CEIL", "CEILING" -> {
                DataType t = numeric(name, args.get(0));
                DataType result = t.kind() == TypeKind.DECIMAL
                        ? DataType.decimal(TypeCoercion.resultPrecision(t), 0) : t;
                yield new BoundExpr.Function(name.equals("FLOOR") ? "FLOOR" : "CEIL", args, result);
            }
            case "SQRT" -> {
                numeric(name, args.get(0));
                yield new BoundExpr.Function(name, floats(args), DataType.FLOAT64);
            }
            case "POWER" -> {
                numeric(name, args.get(0));
                numeric(name, args.get(1));
                yield new BoundExpr.Function(name, floats(args), DataType.FLOAT64);
            }
            case "MOD" -> {
                for (BoundExpr a : args) {
                    require(name, a, TypeKind.INT64);
                }
                yield new BoundExpr.Arithmetic(BoundExpr.ArithOp.MOD, TypeCoercion.implicit(args.get(0), DataType.INT64),
                        TypeCoercion.implicit(args.get(1), DataType.INT64), DataType.INT64);
            }
            case "LENGTH" -> {
                require(name, args.get(0), TypeKind.STRING);
                yield new BoundExpr.Function(name, args, DataType.INT64);
            }
            case "UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM", "REPLACE" -> {
                for (BoundExpr a : args) {
                    require(name, a, TypeKind.STRING);
                }
                yield new BoundExpr.Function(name, args, DataType.STRING);
            }
            case "SUBSTR", "SUBSTRING" -> {
                require(name, args.get(0), TypeKind.STRING);
                for (int i = 1; i < args.size(); i++) {
                    require(name, args.get(i), TypeKind.INT64);
                }
                yield new BoundExpr.Function("SUBSTR", args, DataType.STRING);
            }
            case "CONCAT" -> {
                for (BoundExpr a : args) {
                    if (a.type().kind() == TypeKind.FLOAT64) {
                        throw typeError("CONCAT does not accept FLOAT64 arguments");
                    }
                }
                yield new BoundExpr.Function(name, args, DataType.STRING);
            }
            case "COALESCE" -> {
                List<DataType> types = new ArrayList<>();
                for (BoundExpr a : args) {
                    types.add(a.type());
                }
                DataType t = TypeCoercion.commonType(types, "COALESCE");
                yield new BoundExpr.Function(name, TypeCoercion.castAll(args, t), t);
            }
            case "NULLIF" -> {
                BoundExpr a = args.get(0);
                BoundExpr eq = TypeCoercion.comparison(BoundExpr.CompareOp.EQ, new BoundExpr.Placeholder(a.type()),
                        args.get(1), "NULLIF");
                yield new BoundExpr.NullIf(a, eq);
            }
            case "YEAR", "MONTH", "DAY" -> {
                BoundExpr a = args.get(0);
                if (!a.type().kind().isTemporal() && !a.type().isNull()) {
                    throw typeError("%s requires a DATE or TIMESTAMP argument, got %s", name, a.type());
                }
                yield new BoundExpr.Function(name, args, DataType.INT64);
            }
            case "HOUR", "MINUTE", "SECOND" -> {
                require(name, args.get(0), TypeKind.TIMESTAMP);
                yield new BoundExpr.Function(name, args, DataType.INT64);
            }
            case "DATE_TRUNC" -> dateTrunc(args);
            case "DATE_DIFF" -> dateDiff(args);
            default -> throw new IllegalStateException("unhandled function " + name);
        };
    }

    private static DataType numeric(String fn, BoundExpr arg) {
        DataType t = arg.type();
        if (!t.isNumeric() && !t.isNull()) {
            throw typeError("%s requires a numeric argument, got %s", fn, t);
        }
        return t;
    }

    private static void require(String fn, BoundExpr arg, TypeKind kind) {
        DataType t = arg.type();
        if (t.kind() != kind && !t.isNull()) {
            throw typeError("%s requires a %s argument, got %s", fn, kind, t);
        }
    }

    private static List<BoundExpr> floats(List<BoundExpr> args) {
        return TypeCoercion.castAll(args, DataType.FLOAT64);
    }

    /** Value of an argument documented as constant; SEMANTIC_ERROR if it is not constant. */
    private static Object constant(String fn, BoundExpr arg) {
        if (!BoundExprs.isConstant(arg)) {
            throw PolyQueryException.of(ErrorCode.SEMANTIC_ERROR, "argument of %s must be a constant", fn);
        }
        return ConstantEvaluator.evaluate(arg);
    }

    private static BoundExpr round(List<BoundExpr> args) {
        BoundExpr x = args.get(0);
        DataType t = numeric("ROUND", x);
        long n = 0;
        if (args.size() == 2) {
            BoundExpr digits = args.get(1);
            if (digits.type().kind() != TypeKind.INT64 && !digits.type().isNull()) {
                throw typeError("ROUND digits must be INT64, got %s", digits.type());
            }
            Object v = constant("ROUND", digits);
            if (v == null) {
                return new BoundExpr.Literal(null, roundType(t, 0));
            }
            n = (Long) v;
        }
        // Rounding beyond ±400 digits is the same as rounding at ±400 for every supported type.
        long clamped = Math.max(-400, Math.min(400, n));
        return new BoundExpr.Function("ROUND", List.of(x, new BoundExpr.Literal(clamped, DataType.INT64)),
                roundType(t, clamped));
    }

    private static DataType roundType(DataType t, long n) {
        if (t.kind() == TypeKind.DECIMAL) {
            return DataType.decimal(TypeCoercion.resultPrecision(t), (int) Math.max(0, Math.min(n, t.scale())));
        }
        return t;
    }

    private static String unit(String fn, BoundExpr arg) {
        require(fn, arg, TypeKind.STRING);
        Object v = constant(fn, arg);
        return v == null ? null : ((String) v).toLowerCase(Locale.ROOT);
    }

    private static void temporal(String fn, BoundExpr arg) {
        if (!arg.type().kind().isTemporal() && !arg.type().isNull()) {
            throw typeError("%s requires a DATE or TIMESTAMP argument, got %s", fn, arg.type());
        }
    }

    private static BoundExpr dateTrunc(List<BoundExpr> args) {
        temporal("DATE_TRUNC", args.get(1));
        String unit = unit("DATE_TRUNC", args.get(0));
        if (unit == null) {
            return new BoundExpr.Literal(null, DataType.TIMESTAMP);
        }
        if (!TRUNC_UNITS.contains(unit)) {
            throw PolyQueryException.of(ErrorCode.INVALID_ARGUMENT, "unknown DATE_TRUNC unit '%s'", unit);
        }
        BoundExpr t = TypeCoercion.implicit(args.get(1), DataType.TIMESTAMP);
        return new BoundExpr.Function("DATE_TRUNC", List.of(new BoundExpr.Literal(unit, DataType.STRING), t),
                DataType.TIMESTAMP);
    }

    private static BoundExpr dateDiff(List<BoundExpr> args) {
        temporal("DATE_DIFF", args.get(1));
        temporal("DATE_DIFF", args.get(2));
        String unit = unit("DATE_DIFF", args.get(0));
        if (unit == null) {
            return new BoundExpr.Literal(null, DataType.INT64);
        }
        if (!unit.equals("day")) {
            throw PolyQueryException.of(ErrorCode.INVALID_ARGUMENT, "unknown DATE_DIFF unit '%s'", unit);
        }
        // Only the date parts matter: compare whole days.
        BoundExpr a = TypeCoercion.implicit(args.get(1), DataType.DATE);
        BoundExpr b = TypeCoercion.implicit(args.get(2), DataType.DATE);
        return new BoundExpr.Function("DATE_DIFF", List.of(new BoundExpr.Literal(unit, DataType.STRING), a, b),
                DataType.INT64);
    }
}
