"""Unit tests of pqledger. The polyquery package is found through its path
entry (the implementation directory), as for any program embedding it."""

import os
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
if _ROOT not in sys.path:
    sys.path.insert(0, _ROOT)
