#!/usr/bin/env python3
"""Run the bundled notify-wake local-process adapter."""

from __future__ import annotations

import sys
from pathlib import Path

RUNTIME_ROOT = Path(__file__).parents[1] / "runtime"
sys.path.insert(0, str(RUNTIME_ROOT))

from notify_wake.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
