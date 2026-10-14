"""Process entry point used by bin/pqledger: puts the application and the
polyquery package (a path entry, as for any program embedding the engine)
on sys.path and runs the CLI."""

import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path[:0] = [HERE, os.path.dirname(HERE)]

from pqledger.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8", errors="backslashreplace", newline="\n")
    sys.exit(main(sys.argv[1:]))
