package polyquery.server;

import java.util.ArrayDeque;
import polyquery.common.ErrorCode;
import polyquery.common.PolyQueryException;
import polyquery.exec.QueryControl;

/**
 * Admission control (concurrency.md §2): at most {@code workers} queries execute at once and at
 * most {@code queueDepth} more wait for a worker in FIFO order; anything beyond is rejected
 * immediately with OVERLOADED. Waiting queries still observe their deadline and cancellation.
 */
final class Admission {
    private static final long MAX_WAIT_SLICE_MS = 10;

    private final int workers;
    private final int queueDepth;
    private final ArrayDeque<QueryControl> queue = new ArrayDeque<>();
    private int running;
    private boolean closed;

    Admission(int workers, int queueDepth) {
        this.workers = workers;
        this.queueDepth = queueDepth;
    }

    /** Waits for a worker slot; OVERLOADED, SHUTTING_DOWN, TIMEOUT or CANCELLED otherwise. */
    synchronized void acquire(QueryControl control) {
        if (closed) {
            throw new PolyQueryException(ErrorCode.SHUTTING_DOWN, "server is shutting down");
        }
        control.check();
        if (running < workers && queue.isEmpty()) {
            running++;
            return;
        }
        if (queue.size() >= queueDepth) {
            throw PolyQueryException.of(ErrorCode.OVERLOADED,
                    "server overloaded: %d queries running and %d queued", running, queue.size());
        }
        queue.addLast(control);
        try {
            while (true) {
                if (queue.peekFirst() == control && running < workers) {
                    queue.removeFirst();
                    running++;
                    notifyAll();
                    return;
                }
                control.check();
                long remainingMs = control.remainingNanos() / 1_000_000L + 1;
                wait(Math.max(1, Math.min(MAX_WAIT_SLICE_MS, remainingMs)));
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            queue.remove(control);
            notifyAll();
            throw new PolyQueryException(ErrorCode.CANCELLED, "query was interrupted while queued");
        } catch (RuntimeException e) {
            queue.remove(control);
            notifyAll();
            throw e;
        }
    }

    synchronized void release() {
        running--;
        notifyAll();
    }

    /** Wakes queued queries so they notice a cancellation promptly. */
    synchronized void wakeUp() {
        notifyAll();
    }

    /** Rejects new arrivals with SHUTTING_DOWN; queued queries keep their place. */
    synchronized void close() {
        closed = true;
    }

    synchronized int running() {
        return running;
    }

    synchronized int queued() {
        return queue.size();
    }
}
