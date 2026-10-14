package pqledger;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;

/** Minimal test runner for the application: runs every static no-argument method named test*. */
public final class AppTestMain {
    private AppTestMain() {
    }

    public static void main(String[] args) throws Exception {
        List<Class<?>> suites = List.of(ImporterTest.class, ConfigTest.class, CliTest.class, OutputTest.class,
                ApplicationTest.class);
        int passed = 0;
        int failed = 0;
        for (Class<?> suite : suites) {
            for (Method m : suite.getDeclaredMethods()) {
                if (!m.getName().startsWith("test") || !Modifier.isStatic(m.getModifiers())
                        || m.getParameterCount() != 0) {
                    continue;
                }
                try {
                    m.setAccessible(true);
                    m.invoke(null);
                    passed++;
                } catch (InvocationTargetException e) {
                    failed++;
                    System.out.println("FAIL " + suite.getSimpleName() + "." + m.getName() + ": " + e.getCause());
                }
            }
        }
        System.out.println("pqledger: " + passed + " passed, " + failed + " failed");
        if (failed > 0) {
            System.exit(1);
        }
    }
}
