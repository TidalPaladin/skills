from __future__ import annotations

import os
import signal
import stat
import sys
from pathlib import Path
from typing import Any

import notify_wake.processes as processes
import pytest
from notify_wake.models import TargetIdentity
from notify_wake.processes import (
    AttachedProcess,
    OwnedProcess,
    _decode_wait_status,
    _signal_process_group,
    capture_attached_process,
    monitor_attached_process,
    open_pidfd,
    parse_proc_stat_start_ticks,
    pidfd_supported,
    read_proc_start_ticks,
    spawn_gated_child,
    terminate_owned_process,
    terminate_process_group,
    wait_owned_process,
)
from notify_wake.state import StateError

PID = 4242
START_TICKS = 987654


class FakeKqueue:
    def __init__(self) -> None:
        self.change: object | None = None
        self.closed = False

    def control(
        self,
        changes: list[object] | None,
        max_events: int,
        timeout: float | None,
    ) -> list[object]:
        del max_events, timeout
        if changes is not None:
            self.change = changes[0]
            return []
        return [self.change] if self.change is not None else []

    def close(self) -> None:
        self.closed = True


def attached_target(*, pid: int = PID) -> TargetIdentity:
    return TargetIdentity(
        kind="attached",
        pid=pid,
        process_group_id=None,
        start_ticks=START_TICKS,
        identity_method="linux-pidfd",
    )


@pytest.mark.parametrize(
    ("value", "message"),
    [
        ("4242 worker S 1", "command terminator"),
        ("4242 (worker) S 1", "start-time field"),
        (
            "4242 (worker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 nope",
            "not an integer",
        ),
        (
            "4242 (worker) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 -1",
            "non-negative",
        ),
    ],
)
def test_proc_stat_parser_rejects_malformed_identity(value: str, message: str) -> None:
    with pytest.raises(StateError, match=message):
        parse_proc_stat_start_ticks(value)


@pytest.mark.skipif(
    not sys.platform.startswith("linux"),
    reason="/proc process identity is Linux-only",
)
def test_read_proc_start_ticks_reads_current_process() -> None:
    assert read_proc_start_ticks(os.getpid()) > 0


@pytest.mark.skipif(
    not pidfd_supported(),
    reason="pidfd_open is unavailable on this platform",
)
def test_pidfd_fallback_opens_exact_current_process() -> None:
    descriptor = open_pidfd(os.getpid())
    try:
        assert descriptor >= 0
    finally:
        os.close(descriptor)


def test_read_proc_start_ticks_rejects_non_linux(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    with pytest.raises(StateError, match="Linux"):
        read_proc_start_ticks(PID)


def test_capture_attached_process_success_and_expected_identity() -> None:
    reads: list[int] = []

    attached = capture_attached_process(
        PID,
        expected_start_ticks=START_TICKS,
        pidfd_open=lambda pid: pid + 1,
        start_ticks_reader=lambda pid: reads.append(pid) or START_TICKS,
    )

    assert attached == AttachedProcess(target=attached_target(), pidfd=PID + 1)
    assert reads == [PID, PID]


@pytest.mark.parametrize("pid", [0, -1, True])
def test_capture_attached_process_rejects_invalid_pid(pid: int) -> None:
    with pytest.raises(StateError, match="positive integer"):
        capture_attached_process(
            pid,
            expected_start_ticks=None,
            pidfd_open=lambda _pid: 9,
        )


def test_capture_attached_process_rejects_expected_identity() -> None:
    with pytest.raises(StateError, match="expect-start-ticks"):
        capture_attached_process(
            PID,
            expected_start_ticks=START_TICKS + 1,
            pidfd_open=lambda _pid: 9,
            start_ticks_reader=lambda _pid: START_TICKS,
        )


def test_capture_attached_process_wraps_pidfd_failure() -> None:
    def fail(_pid: int) -> int:
        raise OSError("gone")

    with pytest.raises(StateError, match="could not open pidfd"):
        capture_attached_process(
            PID,
            expected_start_ticks=None,
            pidfd_open=fail,
            start_ticks_reader=lambda _pid: START_TICKS,
        )


def test_capture_attached_process_closes_pidfd_when_second_read_fails() -> None:
    reads = 0
    closed: list[int] = []

    def reader(_pid: int) -> int:
        nonlocal reads
        reads += 1
        if reads == 2:
            raise StateError("identity gone")
        return START_TICKS

    with pytest.raises(StateError, match="identity gone"):
        capture_attached_process(
            PID,
            expected_start_ticks=None,
            pidfd_open=lambda _pid: 9,
            start_ticks_reader=reader,
            close_fd=closed.append,
        )
    assert closed == [9]


def test_monitor_attached_process_handles_ready_and_timeout() -> None:
    read_fd, write_fd = os.pipe()
    os.write(write_fd, b"x")
    os.close(write_fd)
    assert (
        monitor_attached_process(
            AttachedProcess(target=attached_target(), pidfd=read_fd),
            timeout_seconds=0.1,
        )
        == "exited"
    )

    read_fd, write_fd = os.pipe()
    try:
        assert (
            monitor_attached_process(
                AttachedProcess(target=attached_target(), pidfd=read_fd),
                timeout_seconds=0.01,
            )
            == "timed_out"
        )
    finally:
        os.close(write_fd)


def test_monitor_attached_process_rejects_timeout() -> None:
    read_fd, write_fd = os.pipe()
    try:
        with pytest.raises(StateError, match="positive"):
            monitor_attached_process(
                AttachedProcess(target=attached_target(), pidfd=read_fd),
                timeout_seconds=0,
            )
    finally:
        os.close(read_fd)
        os.close(write_fd)


@pytest.mark.parametrize(
    ("shell_command", "status", "exit_code", "signal_number"),
    [
        ("exit 0", "succeeded", 0, None),
        ("exit 3", "failed", 3, None),
        ("kill -TERM $$", "signaled", None, signal.SIGTERM),
    ],
)
def test_owned_process_is_registered_reaped_and_logged(
    tmp_path: Path,
    shell_command: str,
    status: str,
    exit_code: int | None,
    signal_number: int | None,
) -> None:
    registered: list[TargetIdentity] = []
    process_group_ready: list[bool] = []
    process_session_ready: list[bool] = []
    log_path = tmp_path / "logs" / "process.log"

    def register(target: TargetIdentity) -> None:
        registered.append(target)
        process_group_ready.append(os.getpgid(target.pid) == target.process_group_id)
        process_session_ready.append(os.getsid(target.pid) == os.getsid(0))

    owned = spawn_gated_child(
        ["/bin/sh", "-c", f"printf launched; {shell_command}"],
        log_path=log_path,
        register=register,
    )
    outcome = wait_owned_process(owned, timeout_seconds=2)

    assert registered == [owned.target]
    assert process_group_ready == [True]
    assert process_session_ready == [True]
    assert owned.target.kind == "owned"
    assert owned.target.process_group_id == owned.target.pid
    assert outcome.status == status
    assert outcome.exit_code == exit_code
    assert outcome.signal_number == signal_number
    assert log_path.read_text() == "launched"
    assert stat.S_IMODE(log_path.stat().st_mode) == 0o600


def test_owned_process_timeout_cleans_up_process_group(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sent_signals: list[int] = []
    original_signal_owned_process = processes._signal_owned_process

    def record_signal(owned: OwnedProcess, signal_number: int) -> None:
        sent_signals.append(signal_number)
        original_signal_owned_process(owned, signal_number)

    monkeypatch.setattr(processes, "_signal_owned_process", record_signal)
    owned = spawn_gated_child(
        ["/bin/sh", "-c", "sleep 10"],
        log_path=tmp_path / "process.log",
        register=lambda _target: None,
    )
    outcome = wait_owned_process(
        owned,
        timeout_seconds=0.02,
        termination_grace_seconds=0.2,
    )
    assert outcome.status == "timed_out"
    assert sent_signals == [signal.SIGTERM, signal.SIGKILL]
    with pytest.raises(ProcessLookupError):
        os.kill(owned.target.pid, 0)


def test_owned_exit_monitor_uses_prearmed_kqueue_without_waitid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fake_kqueue = FakeKqueue()

    class FakeEvent:
        def __init__(self, ident: int, fflags: int) -> None:
            self.ident = ident
            self.fflags = fflags

    def make_event(
        ident: int,
        *,
        filter: int,
        flags: int,
        fflags: int,
    ) -> FakeEvent:
        assert filter == 1
        assert flags == 6
        return FakeEvent(ident, fflags)

    monkeypatch.delattr(processes.os, "waitid")
    monkeypatch.setattr(processes.sys, "platform", "darwin")
    monkeypatch.setattr(processes.select, "kqueue", lambda: fake_kqueue, raising=False)
    monkeypatch.setattr(processes.select, "kevent", make_event, raising=False)
    monkeypatch.setattr(processes.select, "KQ_FILTER_PROC", 1, raising=False)
    monkeypatch.setattr(processes.select, "KQ_EV_ADD", 2, raising=False)
    monkeypatch.setattr(processes.select, "KQ_EV_ONESHOT", 4, raising=False)
    monkeypatch.setattr(processes.select, "KQ_NOTE_EXIT", 8, raising=False)

    monitor = processes._prepare_owned_exit_monitor(PID)
    monitor.wait()
    monitor.close()

    assert fake_kqueue.closed is True


@pytest.mark.skipif(
    not hasattr(os, "waitid"),
    reason="waitid is unavailable on this Python/platform pair",
)
def test_owned_process_timeout_signals_group_before_reaping_leader(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    leader_waitable_at_kill: list[bool] = []
    original_signal_owned_process = processes._signal_owned_process

    def inspect_leader(owned: OwnedProcess, signal_number: int) -> None:
        if signal_number == signal.SIGKILL:
            try:
                result = os.waitid(
                    os.P_PID,
                    owned.target.pid,
                    os.WEXITED | os.WNOWAIT | os.WNOHANG,
                )
            except ChildProcessError:
                result = None
            leader_waitable_at_kill.append(result is not None)
        original_signal_owned_process(owned, signal_number)

    monkeypatch.setattr(processes, "_signal_owned_process", inspect_leader)
    owned = spawn_gated_child(
        ["/bin/sh", "-c", "sleep 10"],
        log_path=tmp_path / "process.log",
        register=lambda _target: None,
    )

    outcome = wait_owned_process(
        owned,
        timeout_seconds=0.02,
        termination_grace_seconds=0.2,
    )

    assert outcome.status == "timed_out"
    assert leader_waitable_at_kill == [True]


def test_owned_process_wait_interruption_uses_existing_reaper_for_cleanup(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    owned = spawn_gated_child(
        ["/bin/sh", "-c", "sleep 0.2"],
        log_path=tmp_path / "interrupted.log",
        register=lambda _target: None,
    )
    original_get = processes.queue.Queue.get
    get_calls = 0
    sent_signals: list[int] = []
    original_signal_owned_process = processes._signal_owned_process

    def interrupt_first_get(
        selected_queue: Any,
        *args: Any,
        **kwargs: Any,
    ) -> Any:
        nonlocal get_calls
        get_calls += 1
        if get_calls == 1:
            raise RuntimeError("wait interrupted")
        return original_get(selected_queue, *args, **kwargs)

    def record_signal(owned_process: OwnedProcess, signal_number: int) -> None:
        sent_signals.append(signal_number)
        original_signal_owned_process(owned_process, signal_number)

    monkeypatch.setattr(processes.queue.Queue, "get", interrupt_first_get)
    monkeypatch.setattr(processes, "_signal_owned_process", record_signal)

    with pytest.raises(RuntimeError, match="wait interrupted"):
        wait_owned_process(owned, timeout_seconds=1)

    assert sent_signals == [signal.SIGKILL]
    with pytest.raises(ProcessLookupError):
        os.kill(owned.target.pid, 0)


def test_terminate_owned_process_escalates_and_reaps_ignored_term(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    sent_signals: list[int] = []
    original_signal_owned_process = processes._signal_owned_process

    def record_signal(owned: OwnedProcess, signal_number: int) -> None:
        sent_signals.append(signal_number)
        original_signal_owned_process(owned, signal_number)

    monkeypatch.setattr(processes, "_signal_owned_process", record_signal)
    owned = spawn_gated_child(
        ["/bin/sh", "-c", "trap '' TERM; kill -STOP $$; while :; do :; done"],
        log_path=tmp_path / "cleanup.log",
        register=lambda _target: None,
    )
    _, stopped_status = os.waitpid(owned.target.pid, os.WUNTRACED)
    assert os.WIFSTOPPED(stopped_status)

    terminate_owned_process(owned, termination_grace_seconds=0.02)

    assert sent_signals == [signal.SIGTERM, signal.SIGKILL]
    with pytest.raises(ProcessLookupError):
        os.kill(owned.target.pid, 0)


def test_spawn_rejects_invalid_command_and_cleans_failed_registration(
    tmp_path: Path,
) -> None:
    with pytest.raises(StateError, match="non-empty"):
        spawn_gated_child([], log_path=tmp_path / "x", register=lambda _target: None)

    captured_pid: list[int] = []

    def reject(target: TargetIdentity) -> None:
        captured_pid.append(target.pid)
        raise StateError("registration failed")

    with pytest.raises(StateError, match="registration failed"):
        spawn_gated_child(
            ["/bin/sh", "-c", "sleep 10"],
            log_path=tmp_path / "process.log",
            register=reject,
        )
    with pytest.raises(ProcessLookupError):
        os.kill(captured_pid[0], 0)


def test_spawn_rejects_symlinked_process_log_without_touching_target(
    tmp_path: Path,
) -> None:
    outside = tmp_path / "outside.log"
    outside.write_text("outside")
    outside.chmod(0o644)
    log_path = tmp_path / "logs" / "process.log"
    log_path.parent.mkdir()
    log_path.symlink_to(outside)
    registered: list[TargetIdentity] = []

    def reject_registration(target: TargetIdentity) -> None:
        registered.append(target)
        raise StateError("registration should not run")

    with pytest.raises(StateError, match="symlink"):
        spawn_gated_child(
            ["/bin/true"],
            log_path=log_path,
            register=reject_registration,
        )

    assert registered == []
    assert outside.read_text() == "outside"
    assert outside.stat().st_mode & 0o777 == 0o644


@pytest.mark.parametrize("timeout", [0, -1])
def test_wait_owned_process_rejects_invalid_timeout(timeout: float) -> None:
    with pytest.raises(StateError, match="positive"):
        wait_owned_process(
            OwnedProcess(
                TargetIdentity(
                    kind="owned",
                    pid=PID,
                    process_group_id=PID,
                    start_ticks=None,
                    identity_method="parent-handle",
                )
            ),
            timeout_seconds=timeout,
        )


@pytest.mark.skipif(
    not sys.platform.startswith("linux"),
    reason="/proc identity capture is Linux-only",
)
def test_spawn_cleans_gated_child_when_identity_capture_fails(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured_pids: list[int] = []
    cleaned_pids: list[int] = []
    original_cleanup = processes._terminate_unreleased_child

    def fail_identity(pid: int) -> int:
        captured_pids.append(pid)
        raise StateError("identity unavailable")

    def cleanup(pid: int) -> None:
        cleaned_pids.append(pid)
        original_cleanup(pid)

    monkeypatch.setattr(processes, "read_proc_start_ticks", fail_identity)
    monkeypatch.setattr(processes, "_terminate_unreleased_child", cleanup)
    try:
        with pytest.raises(StateError, match="identity unavailable"):
            spawn_gated_child(
                ["/bin/true"],
                log_path=tmp_path / "identity-failure.log",
                register=lambda _target: None,
            )
    finally:
        if captured_pids and not cleaned_pids:
            original_cleanup(captured_pids[0])

    assert cleaned_pids == captured_pids


def test_unreleased_child_cleanup_falls_back_to_exact_pid_on_permission_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    signaled_pids: list[tuple[int, int]] = []
    waited_pids: list[tuple[int, int]] = []

    def reject_group(_process_group_id: int, _signal_number: int) -> None:
        raise PermissionError

    monkeypatch.setattr(os, "killpg", reject_group)
    monkeypatch.setattr(
        os,
        "kill",
        lambda pid, signal_number: signaled_pids.append((pid, signal_number)),
    )
    monkeypatch.setattr(
        os,
        "waitpid",
        lambda pid, options: waited_pids.append((pid, options)) or (pid, 0),
    )

    processes._terminate_unreleased_child(PID)

    assert signaled_pids == [(PID, signal.SIGKILL)]
    assert waited_pids == [(PID, 0)]


@pytest.mark.parametrize("process_group_id", [0, -1, True])
def test_terminate_process_group_rejects_invalid_identity(process_group_id: int) -> None:
    with pytest.raises(StateError, match="positive integer"):
        terminate_process_group(process_group_id)


def test_signal_missing_process_group_is_idempotent() -> None:
    _signal_process_group(2_000_000_000, signal.SIGTERM)


def test_owned_process_signal_does_not_fall_back_to_reused_pid(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    owned = OwnedProcess(
        TargetIdentity(
            kind="owned",
            pid=PID,
            process_group_id=PID,
            start_ticks=None,
            identity_method="parent-handle",
        )
    )
    signaled_pids: list[tuple[int, int]] = []

    def missing_group(_process_group_id: int, _signal_number: int) -> None:
        raise ProcessLookupError

    def record_pid(pid: int, signal_number: int) -> None:
        signaled_pids.append((pid, signal_number))

    monkeypatch.setattr(os, "killpg", missing_group)
    monkeypatch.setattr(os, "kill", record_pid)
    signal_owned = getattr(
        processes,
        "_signal_owned_process",
        lambda selected, signal_number: processes._signal_process_group(
            selected.target.process_group_id or 0,
            signal_number,
        ),
    )

    signal_owned(owned, signal.SIGTERM)

    assert signaled_pids == []


@pytest.mark.parametrize(
    ("platform", "should_raise"),
    [("darwin", False), ("linux", True)],
)
def test_post_exit_group_signal_only_tolerates_darwin_permission_error(
    monkeypatch: pytest.MonkeyPatch,
    platform: str,
    should_raise: bool,
) -> None:
    owned = OwnedProcess(
        TargetIdentity(
            kind="owned",
            pid=PID,
            process_group_id=PID,
            start_ticks=None,
            identity_method="parent-handle",
        )
    )
    monkeypatch.setattr(sys, "platform", platform)

    def deny_group_signal(_owned: OwnedProcess, _signal_number: int) -> None:
        raise PermissionError

    monkeypatch.setattr(processes, "_signal_owned_process", deny_group_signal)

    if should_raise:
        with pytest.raises(PermissionError):
            processes._signal_process_group_after_leader_exit(owned)
    else:
        processes._signal_process_group_after_leader_exit(owned)


def test_decode_wait_status_rejects_nonterminal_status() -> None:
    with pytest.raises(StateError, match="unsupported"):
        _decode_wait_status((signal.SIGSTOP << 8) | 0x7F)
