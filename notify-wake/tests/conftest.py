from __future__ import annotations

import sys
from pathlib import Path

RUNTIME_ROOT = Path(__file__).parents[1] / "runtime"
sys.path.insert(0, str(RUNTIME_ROOT))
