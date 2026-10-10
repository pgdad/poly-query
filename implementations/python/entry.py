"""Process entry point used by bin/polyquery."""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from polyquery.cli import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
