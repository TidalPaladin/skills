"""Exact-path durable state storage for notify-wake."""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import stat
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast
from uuid import uuid4

from .models import (
    SCHEMA_VERSION,
    ModelError,
    NotificationRecord,
    NotifyWaitLease,
    TerminalRecord,
    WakeContext,
    WatchRecord,
    validate_uuid,
)

ROOT_MARKER = ".notify-wake-root.json"
ROOT_KIND = "codex-notify-wake"
WATCH_FILENAME = "watch.json"
WAKE_CONTEXT_FILENAME = "wake-context.json"
GOAL_WAIT_FILENAME = "goal-wait.json"
TERMINAL_FILENAME = "terminal.json"
NOTIFICATION_FILENAME = "notification.json"
PROCESS_LOG_FILENAME = "process.log"
CONTROLLER_LOG_FILENAME = "controller.jsonl"
STATE_LOCK_FILENAME = ".state.lock"
THREAD_LOCK_DIRECTORY = ".thread-locks"


class StateError(RuntimeError):
    """Managed notify-wake state cannot be accessed safely."""


def default_state_root(environment: dict[str, str] | None = None) -> Path:
    selected_environment = os.environ if environment is None else environment
    codex_home = selected_environment.get("CODEX_HOME")
    base = Path(codex_home).expanduser() if codex_home else Path.home() / ".codex"
    if not base.is_absolute():
        raise StateError("CODEX_HOME must be an absolute path")
    resolved_base = base.resolve(strict=False)
    if resolved_base == Path("/"):
        raise StateError("CODEX_HOME must not resolve to the filesystem root")
    return resolved_base / "notify-wake" / f"v{SCHEMA_VERSION}"


@contextmanager
def locked_file(path: Path) -> Iterator[None]:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = open_private_regular_file(path, os.O_RDWR | os.O_CREAT)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


class WatchStore:
    """State store that resolves only explicitly named watch UUIDs."""

    def __init__(self, root: Path) -> None:
        requested = root.expanduser()
        if not requested.is_absolute():
            raise StateError("notify-wake state root must be absolute")
        self.root = Path(os.path.abspath(requested))
        if self.root == Path("/") or self.root == Path.home():
            raise StateError("notify-wake state root is too broad")

    @classmethod
    def from_environment(
        cls,
        environment: dict[str, str] | None = None,
    ) -> WatchStore:
        return cls(default_state_root(environment))

    def initialize(self) -> None:
        if self.root.is_symlink():
            raise StateError("notify-wake state root must not be a symlink")
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        marker = self.root / ROOT_MARKER
        if marker.is_symlink():
            raise StateError("notify-wake root marker must not be a symlink")
        expected: dict[str, object] = {
            "schema_version": SCHEMA_VERSION,
            "kind": ROOT_KIND,
            "root_path": str(self.root),
        }
        if marker.exists():
            payload = self._load_json(marker)
            if payload.get("schema_version") != SCHEMA_VERSION:
                raise StateError("unsupported notify-wake contract; cutover required")
            if payload != expected:
                raise StateError("notify-wake root marker does not match the exact root")
        else:
            self._atomic_write_json(marker, expected)
        thread_locks = self.root / THREAD_LOCK_DIRECTORY
        if thread_locks.is_symlink():
            raise StateError("thread-lock directory must not be a symlink")
        thread_locks.mkdir(mode=0o700, exist_ok=True)
        os.chmod(thread_locks, 0o700)

    def validate_root(self) -> None:
        if self.root.is_symlink() or not self.root.is_dir():
            raise StateError("notify-wake state root is unavailable or symlinked")
        marker = self.root / ROOT_MARKER
        if marker.is_symlink() or not marker.is_file():
            raise StateError("notify-wake state root is not registered")
        expected: dict[str, object] = {
            "schema_version": SCHEMA_VERSION,
            "kind": ROOT_KIND,
            "root_path": str(self.root),
        }
        payload = self._load_json(marker)
        if payload.get("schema_version") != SCHEMA_VERSION:
            raise StateError("unsupported notify-wake contract; cutover required")
        if payload != expected:
            raise StateError("notify-wake root marker does not match the exact root")

    def watch_dir(self, watch_id: str, *, create: bool = False) -> Path:
        try:
            validated = validate_uuid(watch_id, "watch_id")
        except ModelError as error:
            raise StateError(str(error)) from error
        self.validate_root()
        path = self.root / validated
        if path.is_symlink():
            raise StateError("watch directory must not be a symlink")
        resolved = path.resolve(strict=False)
        if resolved.parent != self.root.resolve(strict=True):
            raise StateError("watch directory escapes the managed root")
        if create:
            if path.exists():
                raise StateError(f"watch already exists: {validated}")
            path.mkdir(mode=0o700)
            os.chmod(path, 0o700)
            self._fsync_directory(self.root)
        elif not path.is_dir():
            raise StateError(f"watch does not exist: {validated}")
        return path

    def create_watch(self, watch: WatchRecord, context: WakeContext) -> Path:
        if watch.lifecycle not in {"prepared", "active"}:
            raise StateError("new watch must be prepared or active")
        path = self.watch_dir(watch.watch_id, create=True)
        with locked_file(path / STATE_LOCK_FILENAME):
            self._atomic_write_json(path / WAKE_CONTEXT_FILENAME, context.to_dict())
            self._atomic_write_json(path / WATCH_FILENAME, watch.to_dict())
        return path

    def read_watch(self, watch_id: str) -> WatchRecord:
        return WatchRecord.from_dict(self._read_watch_json(watch_id, WATCH_FILENAME))

    def read_wake_context(self, watch_id: str) -> WakeContext:
        return WakeContext.from_dict(self._read_watch_json(watch_id, WAKE_CONTEXT_FILENAME))

    def read_goal_wait_lease(self, watch_id: str) -> NotifyWaitLease | None:
        path = self.watch_dir(watch_id) / GOAL_WAIT_FILENAME
        if not path.exists():
            return None
        return NotifyWaitLease.from_dict(self._load_json(path))

    def write_goal_wait_lease(
        self,
        watch_id: str,
        lease: NotifyWaitLease,
    ) -> None:
        path = self.watch_dir(watch_id)
        context = WakeContext.from_dict(self._load_json(path / WAKE_CONTEXT_FILENAME))
        if lease.thread_id != context.thread_id:
            raise StateError("goal-wait lease task ID does not match the wake context")
        with locked_file(path / STATE_LOCK_FILENAME):
            self._atomic_write_json(path / GOAL_WAIT_FILENAME, lease.to_dict())

    def read_terminal(self, watch_id: str) -> TerminalRecord:
        return TerminalRecord.from_dict(self._read_watch_json(watch_id, TERMINAL_FILENAME))

    def read_notification(self, watch_id: str) -> NotificationRecord:
        return NotificationRecord.from_dict(self._read_watch_json(watch_id, NOTIFICATION_FILENAME))

    def ensure_notification(self, watch_id: str) -> NotificationRecord:
        """Recover notification state after terminal truth was committed."""

        path = self.watch_dir(watch_id)
        with locked_file(path / STATE_LOCK_FILENAME):
            notification_path = path / NOTIFICATION_FILENAME
            terminal = TerminalRecord.from_dict(self._load_json(path / TERMINAL_FILENAME))
            context = WakeContext.from_dict(self._load_json(path / WAKE_CONTEXT_FILENAME))
            if notification_path.exists():
                notification = NotificationRecord.from_dict(self._load_json(notification_path))
            else:
                notification = NotificationRecord.pending(
                    watch_id=watch_id,
                    event_id=terminal.event_id,
                    thread_id=context.thread_id,
                    attention_required=terminal.attention_required,
                )
            if notification.watch_id != watch_id:
                raise StateError("notification watch ID does not match the requested watch")
            if notification.event_id != terminal.event_id:
                raise StateError("notification does not match the terminal event")
            if notification.thread_id != context.thread_id:
                raise StateError("notification task ID does not match the wake context")
            watch = WatchRecord.from_dict(self._load_json(path / WATCH_FILENAME))
            if watch.target != terminal.target:
                raise StateError("terminal target does not match the registered watch")
            expected_lifecycle = (
                "closed"
                if not terminal.attention_required or notification.state == "accepted"
                else "complete"
            )
            if watch.lifecycle != expected_lifecycle:
                recovered_watch = watch.with_lifecycle(
                    expected_lifecycle,
                    terminal.occurred_at,
                )
                self._atomic_write_json(
                    path / WATCH_FILENAME,
                    recovered_watch.to_dict(),
                )
            if notification_path.exists():
                return notification
            self._atomic_write_json(notification_path, notification.to_dict())
            return notification

    def write_watch(self, watch: WatchRecord) -> None:
        path = self.watch_dir(watch.watch_id)
        with locked_file(path / STATE_LOCK_FILENAME):
            self._atomic_write_json(path / WATCH_FILENAME, watch.to_dict())

    def discard_prepared_watch(self, watch_id: str) -> None:
        """Atomically remove one targetless watch that never became active."""

        path = self.watch_dir(watch_id)
        lock_path = path / STATE_LOCK_FILENAME
        tombstone = self.root / f".discard-{watch_id}-{uuid4()}"
        with locked_file(lock_path):
            watch = WatchRecord.from_dict(self._load_json(path / WATCH_FILENAME))
            if watch.lifecycle != "prepared" or watch.target is not None:
                raise StateError("only a targetless prepared watch can be discarded")
            for filename in (TERMINAL_FILENAME, NOTIFICATION_FILENAME):
                candidate = path / filename
                if candidate.exists() or candidate.is_symlink():
                    raise StateError("prepared watch already contains terminal state")
            os.replace(path, tombstone)
            self._fsync_directory(self.root)
        for filename in (
            WAKE_CONTEXT_FILENAME,
            GOAL_WAIT_FILENAME,
            WATCH_FILENAME,
            PROCESS_LOG_FILENAME,
            CONTROLLER_LOG_FILENAME,
            STATE_LOCK_FILENAME,
        ):
            (tombstone / filename).unlink(missing_ok=True)
        try:
            tombstone.rmdir()
        except OSError as error:
            raise StateError(f"discarded watch contains unexpected files: {tombstone}") from error
        self._fsync_directory(self.root)

    def activate_watch(
        self,
        watch_id: str,
        target: object,
        *,
        now: datetime,
    ) -> WatchRecord:
        from .models import TargetIdentity

        if not isinstance(target, TargetIdentity):
            raise StateError("target must be a TargetIdentity")
        path = self.watch_dir(watch_id)
        with locked_file(path / STATE_LOCK_FILENAME):
            watch = WatchRecord.from_dict(self._load_json(path / WATCH_FILENAME))
            active = watch.activate(target, now)
            self._atomic_write_json(path / WATCH_FILENAME, active.to_dict())
            return active

    def record_terminal(self, terminal: TerminalRecord) -> NotificationRecord:
        path = self.watch_dir(terminal.watch_id)
        with locked_file(path / STATE_LOCK_FILENAME):
            watch = WatchRecord.from_dict(self._load_json(path / WATCH_FILENAME))
            context = WakeContext.from_dict(self._load_json(path / WAKE_CONTEXT_FILENAME))
            if watch.target != terminal.target:
                raise StateError("terminal target does not match the registered watch")
            terminal_path = path / TERMINAL_FILENAME
            if terminal_path.exists():
                current = TerminalRecord.from_dict(self._load_json(terminal_path))
                if current != terminal:
                    raise StateError("watch already has a different terminal event")
                notification_path = path / NOTIFICATION_FILENAME
                if notification_path.exists():
                    return NotificationRecord.from_dict(self._load_json(notification_path))
            self._atomic_write_json(terminal_path, terminal.to_dict())
            lifecycle = "complete" if terminal.attention_required else "closed"
            self._atomic_write_json(
                path / WATCH_FILENAME,
                watch.with_lifecycle(lifecycle, terminal.occurred_at).to_dict(),
            )
            notification = NotificationRecord.pending(
                watch_id=terminal.watch_id,
                event_id=terminal.event_id,
                thread_id=context.thread_id,
                attention_required=terminal.attention_required,
            )
            self._atomic_write_json(
                path / NOTIFICATION_FILENAME,
                notification.to_dict(),
            )
            return notification

    def write_notification(
        self,
        watch_id: str,
        notification: NotificationRecord,
    ) -> None:
        if notification.watch_id != watch_id:
            raise StateError("notification watch ID does not match target watch")
        path = self.watch_dir(watch_id)
        with locked_file(path / STATE_LOCK_FILENAME):
            terminal = TerminalRecord.from_dict(self._load_json(path / TERMINAL_FILENAME))
            if terminal.event_id != notification.event_id:
                raise StateError("notification event does not match terminal truth")
            self._atomic_write_json(
                path / NOTIFICATION_FILENAME,
                notification.to_dict(),
            )

    def close_watch(self, watch_id: str, *, now: datetime) -> WatchRecord:
        path = self.watch_dir(watch_id)
        with locked_file(path / STATE_LOCK_FILENAME):
            watch = WatchRecord.from_dict(self._load_json(path / WATCH_FILENAME))
            closed = watch.with_lifecycle("closed", now)
            self._atomic_write_json(path / WATCH_FILENAME, closed.to_dict())
            return closed

    @contextmanager
    def thread_lock(self, thread_id: str) -> Iterator[Path]:
        lock_path, descriptor = self.acquire_thread_lock(thread_id)
        try:
            yield lock_path
        finally:
            self.release_thread_lock(descriptor)

    def acquire_thread_lock(self, thread_id: str) -> tuple[Path, int]:
        """Acquire one cross-process task lock and return its open descriptor."""

        digest = hashlib.sha256(thread_id.encode()).hexdigest()
        lock_path = self.root / THREAD_LOCK_DIRECTORY / f"{digest}.lock"
        descriptor = open_private_regular_file(lock_path, os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        except BaseException:
            os.close(descriptor)
            raise
        return lock_path, descriptor

    @staticmethod
    def release_thread_lock(descriptor: int) -> None:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)

    def read_accepted_ledger(
        self,
        lock_path: Path,
        thread_id: str,
    ) -> dict[str, dict[str, str]]:
        path = lock_path.with_suffix(".accepted.json")
        if not path.exists():
            return {}
        payload = self._load_json(path)
        if payload.get("schema_version") != SCHEMA_VERSION:
            raise StateError("unsupported notify-wake contract; cutover required")
        if payload.get("thread_id") != thread_id or not isinstance(payload.get("events"), dict):
            raise StateError("accepted-event ledger is invalid")
        events = cast(dict[object, object], payload["events"])
        if not all(
            isinstance(key, str)
            and isinstance(value, dict)
            and all(
                isinstance(item_key, str) and isinstance(item_value, str)
                for item_key, item_value in value.items()
            )
            for key, value in events.items()
        ):
            raise StateError("accepted-event ledger entries are invalid")
        return cast(dict[str, dict[str, str]], events)

    def write_accepted_ledger(
        self,
        lock_path: Path,
        thread_id: str,
        events: dict[str, dict[str, str]],
    ) -> None:
        self._atomic_write_json(
            lock_path.with_suffix(".accepted.json"),
            {
                "schema_version": SCHEMA_VERSION,
                "thread_id": thread_id,
                "events": events,
            },
        )

    def append_controller_log(
        self,
        watch_id: str,
        *,
        event: str,
        detail: str | None = None,
        occurred_at: datetime | None = None,
    ) -> None:
        path = self.watch_dir(watch_id) / CONTROLLER_LOG_FILENAME
        selected_at = (occurred_at or datetime.now(UTC)).astimezone(UTC)
        record: dict[str, object] = {
            "event": _sanitize_log_text(event),
            "occurred_at": selected_at.isoformat(),
        }
        if detail is not None:
            record["detail"] = _sanitize_log_text(detail)
        descriptor = open_private_regular_file(
            path,
            os.O_WRONLY | os.O_APPEND | os.O_CREAT,
        )
        try:
            payload = json.dumps(record, sort_keys=True, separators=(",", ":"))
            os.write(descriptor, payload.encode() + b"\n")
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def _read_watch_json(self, watch_id: str, filename: str) -> dict[str, Any]:
        path = self.watch_dir(watch_id) / filename
        if path.is_symlink():
            raise StateError(f"{filename} must not be a symlink")
        if not path.is_file():
            raise StateError(f"{filename} is missing")
        return self._load_json(path)

    def _load_json(self, path: Path) -> dict[str, Any]:
        if path.is_symlink():
            raise StateError(f"state file must not be a symlink: {path}")
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            raise
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise StateError(f"state file is not valid JSON: {path}: {error}") from error
        if not isinstance(payload, dict) or not all(isinstance(key, str) for key in payload):
            raise StateError(f"state file must contain a JSON object: {path}")
        return cast(dict[str, Any], payload)

    def _atomic_write_json(
        self,
        path: Path,
        payload: dict[str, object],
    ) -> None:
        if path.is_symlink():
            raise StateError(f"state destination must not be a symlink: {path}")
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor, temporary_name = tempfile.mkstemp(
            dir=path.parent,
            prefix=f".{path.name}.",
            suffix=".tmp",
        )
        temporary = Path(temporary_name)
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump(payload, stream, indent=2, sort_keys=True)
                stream.write("\n")
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, path)
            os.chmod(path, 0o600)
            self._fsync_directory(path.parent)
        except BaseException:
            temporary.unlink(missing_ok=True)
            raise

    @staticmethod
    def _fsync_directory(directory: Path) -> None:
        flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
        descriptor = os.open(directory, flags)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


def _sanitize_log_text(value: str) -> str:
    normalized = " ".join(
        "".join(
            character if ord(character) >= 32 and ord(character) != 127 else " "
            for character in value
        ).split()
    )
    return normalized[:500] or "unspecified"


def ensure_regular_private_file(path: Path) -> None:
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
        raise StateError(f"state file is not a private regular file: {path}")


def open_private_regular_file(path: Path, flags: int) -> int:
    """Open one managed private regular file without following symlinks."""

    no_follow = getattr(os, "O_NOFOLLOW", None)
    directory_flag = getattr(os, "O_DIRECTORY", None)
    if no_follow is None or directory_flag is None:
        raise StateError("host does not support safe managed-file access")
    if path.parent.is_symlink() or path.is_symlink():
        raise StateError(f"managed file path must not contain a symlink: {path}")
    try:
        parent_descriptor = os.open(
            path.parent,
            os.O_RDONLY | directory_flag | no_follow,
        )
        try:
            descriptor = os.open(
                path.name,
                flags | no_follow,
                0o600,
                dir_fd=parent_descriptor,
            )
        finally:
            os.close(parent_descriptor)
    except OSError as error:
        raise StateError(f"could not safely open managed file: {path}: {error}") from error
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            raise StateError(f"managed file is not a private regular file: {path}")
        os.fchmod(descriptor, 0o600)
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor
