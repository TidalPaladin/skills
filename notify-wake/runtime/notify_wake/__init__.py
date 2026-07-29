"""Strict local-process notification adapter for Codex tasks."""

from .models import (
    NotificationRecord,
    TargetIdentity,
    TerminalRecord,
    WakeContext,
    WatchRecord,
)
from .state import WatchStore

__all__ = [
    "NotificationRecord",
    "TargetIdentity",
    "TerminalRecord",
    "WakeContext",
    "WatchRecord",
    "WatchStore",
]
