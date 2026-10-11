package polyquery.ffi;

/** The native kernel library could not be loaded or bound. */
public final class NativeLoadException extends Exception {
    private static final long serialVersionUID = 1L;

    public NativeLoadException(String message) {
        super(message);
    }
}
