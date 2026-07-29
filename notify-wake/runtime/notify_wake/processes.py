"""Unix process identity, supervision, and pidfd monitoring."""

from __future__ import annotations

import ctypes
import os
import queue
import select
import selectors
import signal
import sys
import threading
from collections.abc import Callable, Sequence
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal, Protocol

from .models import TargetIdentity
from .state import StateError, open_private_regular_file

PROCESS_TERMINATION_GRACE_SECONDS = 10.0
EXEC_FAILURE_EXIT_CODE = 127


@dataclass(frozen=True, slots=True)
class AttachedProcess:
    """An exact Linux process handle owned only by the monitor."""

    target: TargetIdentity
    pidfd: int


class _OwnedExitMonitor(Protocol):
    def wait(self) -> None: ...

    def close(self) -> None: ...


@dataclass(frozen=True, slots=True)
class _WaitIdExitMonitor:
    pid: int

    def wait(self) -> None:
        result = os.waitid(
            os.P_PID,
            self.pid,
            os.WEXITED | os.WNOWAIT,
        )
        if result is None:
            raise StateError("owned process exit monitor returned no result")

    def close(self) -> None:
        return


@dataclass(frozen=True, slots=True)
class _KqueueExitMonitor:
    pid: int
    monitor: Any
    note_exit: int

    def wait(self) -> None:
        events = self.monitor.control(None, 1, None)
        if len(events) != 1 or events[0].ident != self.pid or not events[0].fflags & self.note_exit:
            raise StateError("owned process kqueue monitor returned an invalid event")

    def close(self) -> None:
        self.monitor.close()


@dataclass(frozen=True, slots=True)
class OwnedProcess:
    """A gated child process owned and reaped by the supervisor."""

    target: TargetIdentity
    exit_monitor: _OwnedExitMonitor | None = None


@dataclass(frozen=True, slots=True)
class OwnedProcessOutcome:
    """Final status returned after reaping an owned child."""

    status: Literal["succeeded", "failed", "signaled", "timed_out"]
    exit_code: int | None
    signal_number: int | None


@dataclass(slots=True)
class _OwnedExitObserver:
    monitor: _OwnedExitMonitor
    result_queue: queue.Queue[BaseException | None]
    thread: threading.Thread
    received: bool = False

    def wait(self, timeout_seconds: float | None = None) -> None:
        if self.received:
            raise StateError("owned process exit was already observed")
        if timeout_seconds is None:
            result = self.result_queue.get()
        else:
            result = self.result_queue.get(timeout=timeout_seconds)
        self.received = True
        if result is not None:
            raise StateError(f"owned process exit monitor failed: {result}") from result

    def close(self) -> None:
        self.thread.join()
        self.monitor.close()


def _prepare_owned_exit_monitor(pid: int) -> _OwnedExitMonitor:
    if callable(getattr(os, "waitid", None)):
        return _WaitIdExitMonitor(pid)
    if sys.platform != "darwin":
        raise StateError("this platform cannot observe child exit without reaping")

    kqueue_factory = getattr(select, "kqueue", None)
    kevent_factory = getattr(select, "kevent", None)
    if not callable(kqueue_factory) or not callable(kevent_factory):
        raise StateError("macOS kqueue process monitoring is unavailable")
    filter_process = _select_integer_constant("KQ_FILTER_PROC")
    add_event = _select_integer_constant("KQ_EV_ADD")
    one_shot = _select_integer_constant("KQ_EV_ONESHOT")
    note_exit = _select_integer_constant("KQ_NOTE_EXIT")
    monitor: Any = kqueue_factory()
    try:
        change = kevent_factory(
            pid,
            filter=filter_process,
            flags=add_event | one_shot,
            fflags=note_exit,
        )
        monitor.control([change], 0, 0)
    except BaseException as error:
        monitor.close()
        raise StateError(f"could not arm the owned process exit monitor: {error}") from error
    return _KqueueExitMonitor(pid=pid, monitor=monitor, note_exit=note_exit)


def _select_integer_constant(name: str) -> int:
    value = getattr(select, name, None)
    if not isinstance(value, int):
        raise StateError(f"platform process-monitor constant is unavailable: {name}")
    return value


def _start_owned_exit_observer(owned: OwnedProcess) -> _OwnedExitObserver:
    monitor = owned.exit_monitor
    if monitor is None:
        raise StateError("owned process lacks an armed exit monitor")
    result_queue: queue.Queue[BaseException | None] = queue.Queue(maxsize=1)

    def observe() -> None:
        try:
            monitor.wait()
        except BaseException as error:
            result_queue.put(error)
        else:
            result_queue.put(None)

    thread = threading.Thread(
        target=observe,
        name=f"notify-wake-exit-observer-{owned.target.pid}",
        daemon=False,
    )
    thread.start()
    return _OwnedExitObserver(
        monitor=monitor,
        result_queue=result_queue,
        thread=thread,
    )


def _reap_owned_process(owned: OwnedProcess) -> int:
    try:
        waited_pid, wait_status = os.waitpid(owned.target.pid, 0)
    except (ChildProcessError, OSError) as error:
        raise StateError(f"could not reap owned process: {error}") from error
    if waited_pid != owned.target.pid:
        raise StateError("reaped an unexpected owned process")
    return wait_status


def parse_proc_stat_start_ticks(value: str) -> int:
    """Parse Linux ``/proc/<pid>/stat`` field 22 without splitting ``comm``."""

    closing_parenthesis = value.rfind(")")
    if closing_parenthesis < 1:
        raise StateError("process stat is missing the command terminator")
    fields_after_command = value[closing_parenthesis + 1 :].strip().split()
    start_time_index = 19
    if len(fields_after_command) <= start_time_index:
        raise StateError("process stat is missing the start-time field")
    try:
        start_ticks = int(fields_after_command[start_time_index])
    except ValueError as error:
        raise StateError("process start time is not an integer") from error
    if start_ticks < 0:
        raise StateError("process start time must be non-negative")
    return start_ticks


def read_proc_start_ticks(pid: int) -> int:
    if not sys.platform.startswith("linux"):
        raise StateError("Linux /proc process identity is unavailable on this platform")
    path = Path("/proc") / str(pid) / "stat"
    try:
        value = path.read_text(encoding="utf-8")
    except OSError as error:
        raise StateError(f"could not read process identity for PID {pid}: {error}") from error
    return parse_proc_stat_start_ticks(value)


def capture_attached_process(
    pid: int,
    *,
    expected_start_ticks: int | None,
    pidfd_open: Callable[[int], int] | None = None,
    start_ticks_reader: Callable[[int], int] = read_proc_start_ticks,
    close_fd: Callable[[int], None] = os.close,
) -> AttachedProcess:
    """Capture one exact PID and reject exit or reuse during registration."""

    if not isinstance(pid, int) or isinstance(pid, bool) or pid < 1:
        raise StateError("PID must be a positive integer")
    opener = pidfd_open
    if opener is None:
        opener = open_pidfd
    first_start_ticks = start_ticks_reader(pid)
    if expected_start_ticks is not None and first_start_ticks != expected_start_ticks:
        raise StateError("process start time does not match --expect-start-ticks")
    try:
        pidfd = opener(pid)
    except OSError as error:
        raise StateError(f"could not open pidfd for PID {pid}: {error}") from error
    try:
        second_start_ticks = start_ticks_reader(pid)
    except BaseException:
        close_fd(pidfd)
        raise
    if first_start_ticks != second_start_ticks:
        close_fd(pidfd)
        raise StateError("process identity changed while attaching")
    return AttachedProcess(
        target=TargetIdentity(
            kind="attached",
            pid=pid,
            process_group_id=None,
            start_ticks=first_start_ticks,
            identity_method="linux-pidfd",
        ),
        pidfd=pidfd,
    )


def pidfd_supported() -> bool:
    """Return whether this Linux runtime can call pidfd_open."""

    if not sys.platform.startswith("linux"):
        return False
    if getattr(os, "pidfd_open", None) is not None:
        return True
    try:
        _libc_pidfd_open()
    except StateError:
        return False
    return True


def open_pidfd(pid: int) -> int:
    """Open a pidfd through Python or the host libc wrapper."""

    if not sys.platform.startswith("linux"):
        raise StateError("attach requires Linux pidfd_open support")
    system_opener = getattr(os, "pidfd_open", None)
    if system_opener is not None:
        return system_opener(pid)
    function = _libc_pidfd_open()
    descriptor = function(pid, 0)
    if descriptor < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return descriptor


def _libc_pidfd_open() -> Any:
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        function = libc.pidfd_open
    except (AttributeError, OSError) as error:
        raise StateError("host libc does not expose pidfd_open") from error
    function.argtypes = [ctypes.c_int, ctypes.c_uint]
    function.restype = ctypes.c_int
    return function


def monitor_attached_process(
    attached: AttachedProcess,
    *,
    timeout_seconds: float,
) -> Literal["exited", "timed_out"]:
    """Wait for pidfd readiness; never signal the attached process."""

    if timeout_seconds <= 0:
        raise StateError("timeout_seconds must be positive")
    selector = selectors.DefaultSelector()
    try:
        selector.register(attached.pidfd, selectors.EVENT_READ)
        events = selector.select(timeout_seconds)
        return "exited" if events else "timed_out"
    finally:
        selector.close()
        os.close(attached.pidfd)


def spawn_gated_child(
    command: Sequence[str],
    *,
    log_path: Path,
    register: Callable[[TargetIdentity], None],
) -> OwnedProcess:
    """Fork a child that cannot exec until its exact identity is durable."""

    if not command or not all(isinstance(argument, str) and argument for argument in command):
        raise StateError("command must contain non-empty arguments")
    log_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    log_descriptor = open_private_regular_file(
        log_path,
        os.O_WRONLY | os.O_CREAT | os.O_APPEND,
    )
    gate_read, gate_write = os.pipe()
    readiness_read, readiness_write = os.pipe()
    try:
        pid = os.fork()
    except BaseException:
        for descriptor in (
            gate_read,
            gate_write,
            readiness_read,
            readiness_write,
            log_descriptor,
        ):
            os.close(descriptor)
        raise
    if pid == 0:  # pragma: no cover - exercised in the forked process, not pytest
        try:
            os.close(gate_write)
            os.close(readiness_read)
            # A separate group supports cleanup without crossing sessions on macOS.
            os.setpgid(0, 0)
            os.write(readiness_write, b"1")
            os.close(readiness_write)
            null_descriptor = os.open(os.devnull, os.O_RDONLY)
            try:
                os.dup2(null_descriptor, 0)
            finally:
                os.close(null_descriptor)
            os.dup2(log_descriptor, 1)
            os.dup2(log_descriptor, 2)
            os.close(log_descriptor)
            gate_value = os.read(gate_read, 1)
            os.close(gate_read)
            if gate_value != b"1":
                os._exit(EXEC_FAILURE_EXIT_CODE)
            os.execvpe(command[0], list(command), os.environ.copy())
        except BaseException as error:
            try:
                message = f"notify-wake command launch failed: {error}\n"
                os.write(2, message.encode(errors="replace")[:4096])
            finally:
                os._exit(EXEC_FAILURE_EXIT_CODE)
    os.close(gate_read)
    os.close(readiness_write)
    os.close(log_descriptor)
    exit_monitor: _OwnedExitMonitor | None = None
    try:
        try:
            readiness = os.read(readiness_read, 1)
        finally:
            os.close(readiness_read)
        if readiness != b"1":
            raise StateError("owned child did not establish its process group")
        start_ticks = read_proc_start_ticks(pid) if sys.platform.startswith("linux") else None
        target = TargetIdentity(
            kind="owned",
            pid=pid,
            process_group_id=pid,
            start_ticks=start_ticks,
            identity_method="parent-handle",
        )
        exit_monitor = _prepare_owned_exit_monitor(pid)
        register(target)
        os.write(gate_write, b"1")
    except BaseException:
        if exit_monitor is not None:
            exit_monitor.close()
        os.close(gate_write)
        _terminate_unreleased_child(pid)
        raise
    os.close(gate_write)
    return OwnedProcess(target=target, exit_monitor=exit_monitor)


def wait_owned_process(
    owned: OwnedProcess,
    *,
    timeout_seconds: float,
    termination_grace_seconds: float = PROCESS_TERMINATION_GRACE_SECONDS,
) -> OwnedProcessOutcome:
    """Wait natively and retain sole cleanup ownership once reaping starts."""

    if timeout_seconds <= 0 or termination_grace_seconds <= 0:
        raise StateError("process timeouts must be positive")
    if owned.target.process_group_id is None:
        raise StateError("owned process lacks a process-group identity")
    observer = _start_owned_exit_observer(owned)
    leader_reaped = False
    try:
        try:
            observer.wait(timeout_seconds)
            wait_status = _reap_owned_process(owned)
            leader_reaped = True
            return _decode_wait_status(wait_status)
        except queue.Empty:
            _signal_owned_process(owned, signal.SIGTERM)
            try:
                observer.wait(termination_grace_seconds)
            except queue.Empty:
                _signal_owned_process(owned, signal.SIGKILL)
                observer.wait()
            else:
                _signal_owned_process(owned, signal.SIGKILL)
            _reap_owned_process(owned)
            leader_reaped = True
            return OwnedProcessOutcome(
                status="timed_out",
                exit_code=None,
                signal_number=None,
            )
    except BaseException:
        _signal_owned_process(owned, signal.SIGKILL)
        if not observer.received:
            observer.wait()
        if not leader_reaped:
            _reap_owned_process(owned)
        raise
    finally:
        observer.close()


def terminate_owned_process(
    owned: OwnedProcess,
    *,
    termination_grace_seconds: float = PROCESS_TERMINATION_GRACE_SECONDS,
) -> None:
    """Terminate and reap an owned process group with a bounded TERM grace period."""

    if termination_grace_seconds <= 0:
        raise StateError("termination_grace_seconds must be positive")
    process_group = owned.target.process_group_id
    if process_group is None:
        raise StateError("owned process lacks a process-group identity")
    observer = _start_owned_exit_observer(owned)
    leader_reaped = False
    try:
        _signal_owned_process(owned, signal.SIGTERM)
        try:
            observer.wait(termination_grace_seconds)
        except queue.Empty:
            _signal_owned_process(owned, signal.SIGKILL)
            observer.wait()
        else:
            _signal_owned_process(owned, signal.SIGKILL)
        _reap_owned_process(owned)
        leader_reaped = True
    except BaseException:
        _signal_owned_process(owned, signal.SIGKILL)
        if not observer.received:
            observer.wait()
        if not leader_reaped:
            _reap_owned_process(owned)
        raise
    finally:
        observer.close()


def terminate_process_group(
    process_group_id: int,
    *,
    signal_number: int = signal.SIGTERM,
) -> None:
    """Signal only one validated positive process-group ID."""

    if (
        not isinstance(process_group_id, int)
        or isinstance(process_group_id, bool)
        or process_group_id < 1
    ):
        raise StateError("process_group_id must be a positive integer")
    _signal_process_group(process_group_id, signal_number)


def _decode_wait_status(wait_status: int) -> OwnedProcessOutcome:
    if os.WIFEXITED(wait_status):
        exit_code = os.WEXITSTATUS(wait_status)
        return OwnedProcessOutcome(
            status="succeeded" if exit_code == 0 else "failed",
            exit_code=exit_code,
            signal_number=None,
        )
    if os.WIFSIGNALED(wait_status):
        return OwnedProcessOutcome(
            status="signaled",
            exit_code=None,
            signal_number=os.WTERMSIG(wait_status),
        )
    raise StateError(f"unsupported child wait status: {wait_status}")


def _signal_process_group(process_group_id: int, signal_number: int) -> None:
    try:
        os.killpg(process_group_id, signal_number)
    except ProcessLookupError:
        return


def _signal_owned_process(owned: OwnedProcess, signal_number: int) -> None:
    process_group = owned.target.process_group_id
    if process_group is None:
        raise StateError("owned process lacks a process-group identity")
    _signal_process_group(process_group, signal_number)


def _terminate_unreleased_child(pid: int) -> None:
    try:
        os.killpg(pid, signal.SIGKILL)
    except (PermissionError, ProcessLookupError):
        # The gated direct child cannot exec or fork, so this PID cannot be reused yet.
        with suppress(ProcessLookupError):
            os.kill(pid, signal.SIGKILL)
    with suppress(ChildProcessError):
        os.waitpid(pid, 0)
