package polyquery;

import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;

/** Minimal test runner: invokes every static no-arg method whose name starts with "test". */
public final class TestMain {
    private TestMain() {
    }

    public static void main(String[] args) throws Exception {
        List<Class<?>> suites = List.of(
                LexerTest.class, ParserTest.class, TypesTest.class, IngestTest.class,
                EngineTest.class, QueryTest.class, ProtocolTest.class, StorageTest.class, IndexTest.class,
                polyquery.server.ServerTest.class, Phase5Test.class, polyquery.exec.vector.VectorTest.class,
                NativeKernelsTest.class, polyquery.exec.vector.NativeVectorTest.class,
                polyquery.optimizer.OptimizerRulesTest.class, polyquery.physical.PhysicalPlannerTest.class,
                WideDecimalTest.class);
        int passed = 0;
        int failed = 0;
        for (Class<?> suite : suites) {
            for (Method m : suite.getDeclaredMethods()) {
                if (!m.getName().startsWith("test") || !Modifier.isStatic(m.getModifiers())) {
                    continue;
                }
                try {
                    m.setAccessible(true);
                    m.invoke(null);
                    passed++;
                } catch (java.lang.reflect.InvocationTargetException e) {
                    failed++;
                    System.out.println("FAIL " + suite.getSimpleName() + "." + m.getName() + ": " + e.getCause());
                }
            }
        }
        System.out.println(passed + " passed, " + failed + " failed");
        if (failed > 0) {
            System.exit(1);
        }
    }
}
