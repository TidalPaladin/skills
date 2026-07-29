from __future__ import annotations

import argparse
import asyncio
import io
import json
import os
import selectors
import signal
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, cast

import notify_wake.cli as cli
import pytest
from notify_wake.models import (
    Lifecycle,
    NotificationRecord,
    TargetIdentity,
    TerminalRecord,
    WakeContext,
    WakeOn,
    WatchMode,
    WatchRecord,
)
from notify_wake.processes import AttachedProcess, OwnedProcess, OwnedProcessOutcome
from notify_wake.state import NOTIFICATION_FILENAME, StateError, WatchStore

NOW = datetime(2026, 7, 28, 18, 0, tzinfo=UTC)
WATCH_ID = "12345678-1234-5678-9234-567812345678"
EVENT_ID = "22345678-1234-5678-9234-567812345678"
THREAD_ID = "thread-1"


def context(*, goal: dict[str, Any] | None = None) -> WakeContext:
    return WakeContext(
        thread_id=THREAD_ID,
        permission_profile="danger-full-access",
        approval_policy="never",
        captured_at=NOW,
        goal_snapshot=goal,
    )


def attached_target() -> TargetIdentity:
    return TargetIdentity(
        kind="attached",
        pid=4242,
        process_group_id=None,
        start_ticks=99,
        identity_method="linux-pidfd",
    )


def owned_target() -> TargetIdentity:
    return TargetIdentity(
        kind="owned",
        pid=4242,
        process_group_id=4242,
        start_ticks=99,
        identity_method="parent-handle",
    )


def watch_record(
    *,
    mode: str = "attach",
    lifecycle: str = "active",
    selected_target: TargetIdentity | None = None,
    wake_on: str = "always",
    process_log: Path | None = None,
) -> WatchRecord:
    return WatchRecord(
        schema_version=1,
        watch_id=WATCH_ID,
        mode=cast(WatchMode, mode),
        lifecycle=cast(Lifecycle, lifecycle),
        created_at=NOW,
        updated_at=NOW,
        timeout_seconds=2,
        wake_on=cast(WakeOn, wake_on),
        evidence_paths=(),
        process_log_path=str(process_log) if process_log is not None else None,
        target=selected_target,
    )


def terminal() -> TerminalRecord:
    return TerminalRecord(
        schema_version=1,
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        target=attached_target(),
        status="exited",
        exit_code=None,
        signal_number=None,
        occurred_at=NOW,
        attention_required=True,
        evidence_paths=(),
    )


@pytest.fixture
def store(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> WatchStore:
    codex_home = tmp_path / "codex"
    monkeypatch.setenv("CODEX_HOME", str(codex_home))
    selected = WatchStore.from_environment()
    selected.initialize()
    return selected


def parsed(command: list[str]) -> argparse.Namespace:
    return cli.build_parser().parse_args(command)


@pytest.mark.parametrize(
    ("command", "payload", "expected"),
    [
        ("run", {"delivery": "none"}, cli.EXIT_SUCCESS),
        ("attach", {"delivery": "blocked"}, cli.EXIT_ATTENTION),
        ("status", {"delivery": "pending"}, cli.EXIT_ATTENTION),
        ("reconcile", {"delivery": "uncertain"}, cli.EXIT_ATTENTION),
    ],
)
def test_main_dispatches_public_commands(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    command: str,
    payload: dict[str, object],
    expected: int,
) -> None:
    monkeypatch.setattr(cli, f"_{command}_command", lambda *_args: payload)
    arguments = [command, "--format", "json"]
    if command == "run":
        arguments.extend(["--timeout-seconds", "1", "--", "/bin/true"])
    elif command == "attach":
        arguments.extend(["--timeout-seconds", "1", "--pid", "1"])
    else:
        arguments.append(WATCH_ID)

    assert cli.main(arguments) == expected
    assert json.loads(capsys.readouterr().out) == payload


def test_main_preflight_and_error_exit_contracts(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.setattr(
        cli,
        "_preflight",
        lambda: {
            "automatic_delivery_available": False,
            "delivery": "blocked",
            "blocker": "goal",
        },
    )
    assert cli.main(["preflight", "--format", "json"]) == cli.EXIT_ATTENTION
    assert json.loads(capsys.readouterr().out)["delivery"] == "blocked"

    monkeypatch.setattr(
        cli,
        "_status_command",
        lambda _watch_id: (_ for _ in ()).throw(StateError("broken state")),
    )
    assert cli.main(["status", WATCH_ID]) == cli.EXIT_RUNTIME_ERROR
    assert "broken state" in capsys.readouterr().err

    monkeypatch.setattr(
        cli,
        "_status_command",
        lambda _watch_id: (_ for _ in ()).throw(cli.ExpectedProblem("unsafe")),
    )
    assert cli.main(["status", WATCH_ID, "--format", "json"]) == cli.EXIT_ATTENTION
    assert json.loads(capsys.readouterr().out)["error"] == "unsafe"


def test_preflight_reports_authority_and_goal_blocker(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("CODEX_THREAD_ID", THREAD_ID)

    async def capture(**_kwargs: object) -> tuple[WakeContext, Path, str | None]:
        return context(goal={"status": "blocked"}), Path("/tmp/app.sock"), None

    monkeypatch.setattr(cli, "capture_wake_readiness_from_daemon", capture)
    payload = cli._preflight()
    assert payload["delivery"] == "blocked"
    assert payload["permission_profile"] == "danger-full-access"
    assert payload["socket_path"] == "/tmp/app.sock"


def test_preflight_and_launch_context_reject_idle_thread(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("CODEX_THREAD_ID", THREAD_ID)
    idle_blocker = "originating task is idle; atomic idle-start is unavailable"

    async def capture_readiness(
        **_kwargs: object,
    ) -> tuple[WakeContext, Path, str | None]:
        return context(), Path("/tmp/app.sock"), idle_blocker

    monkeypatch.setattr(
        cli,
        "capture_wake_readiness_from_daemon",
        capture_readiness,
    )

    payload = cli._preflight()

    assert payload["automatic_delivery_available"] is False
    assert payload["delivery"] == "blocked"
    assert payload["blocker"] == idle_blocker
    with pytest.raises(cli.ExpectedProblem, match="atomic idle-start"):
        cli._capture_launch_context()


def test_run_command_registers_prepared_watch_without_leaking_arguments(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(cli, "_capture_launch_context", context)
    monkeypatch.setattr(cli, "_launch_supervisor", lambda *_args, **_kwargs: {"status": "active"})
    arguments = parsed(
        [
            "run",
            "--watch-id",
            WATCH_ID,
            "--timeout-seconds",
            "3",
            "--wake-on",
            "failure",
            "--evidence",
            "/tmp/evidence",
            "--",
            "/bin/echo",
            "secret-argument",
        ]
    )

    payload = cli._run_command(arguments)
    selected = store.read_watch(WATCH_ID)
    assert payload["lifecycle"] == "prepared"
    assert selected.wake_on == "failure"
    assert "secret-argument" not in json.dumps(selected.to_dict())
    assert selected.process_log_path in selected.evidence_paths


def test_run_command_rejects_missing_command_goal_and_failed_handshake(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setattr(cli, "_capture_launch_context", context)
    with pytest.raises(ValueError, match="requires a command"):
        cli._run_command(parsed(["run", "--timeout-seconds", "1"]))

    monkeypatch.setattr(cli, "_capture_launch_context", lambda: context(goal={"status": "active"}))
    with pytest.raises(cli.ExpectedProblem, match="persistent goal"):
        cli._run_command(parsed(["run", "--timeout-seconds", "1", "--", "/bin/true"]))

    monkeypatch.setattr(cli, "_capture_launch_context", context)
    monkeypatch.setattr(
        cli,
        "_launch_supervisor",
        lambda *_args, **_kwargs: {"status": "error", "error": "not armed"},
    )
    with pytest.raises(StateError, match="not armed"):
        cli._run_command(
            parsed(
                [
                    "run",
                    "--watch-id",
                    WATCH_ID,
                    "--timeout-seconds",
                    "1",
                    "--",
                    "/bin/true",
                ]
            )
        )
    assert not (store.root / WATCH_ID).exists()


def test_attach_command_captures_exact_handle_and_parent_closes_it(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    read_fd, write_fd = os.pipe()
    monkeypatch.setattr(cli, "_capture_launch_context", context)
    monkeypatch.setattr(
        cli,
        "capture_attached_process",
        lambda *_args, **_kwargs: AttachedProcess(attached_target(), read_fd),
    )
    monkeypatch.setattr(cli, "_launch_supervisor", lambda *_args, **_kwargs: {"status": "active"})

    payload = cli._attach_command(
        parsed(
            [
                "attach",
                "--watch-id",
                WATCH_ID,
                "--timeout-seconds",
                "1",
                "--pid",
                "4242",
            ]
        )
    )
    os.close(write_fd)
    assert payload["lifecycle"] == "active"
    assert store.read_watch(WATCH_ID).target == attached_target()
    with pytest.raises(OSError):
        os.fstat(read_fd)


@pytest.mark.parametrize("failure_mode", ["exception", "error_handshake"])
def test_attach_command_records_monitor_error_when_supervisor_does_not_start(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    failure_mode: str,
) -> None:
    read_fd, write_fd = os.pipe()
    monkeypatch.setattr(cli, "_capture_launch_context", context)
    monkeypatch.setattr(
        cli,
        "capture_attached_process",
        lambda *_args, **_kwargs: AttachedProcess(attached_target(), read_fd),
    )

    def fail_launch(*_args: object, **_kwargs: object) -> dict[str, object]:
        if failure_mode == "exception":
            raise OSError("could not launch")
        return {"status": "error", "error": "not armed"}

    monkeypatch.setattr(cli, "_launch_supervisor", fail_launch)
    arguments = parsed(
        [
            "attach",
            "--watch-id",
            WATCH_ID,
            "--timeout-seconds",
            "1",
            "--pid",
            "4242",
        ]
    )

    expected_error = OSError if failure_mode == "exception" else StateError
    with pytest.raises(expected_error):
        cli._attach_command(arguments)
    os.close(write_fd)

    assert store.read_terminal(WATCH_ID).status == "monitor_error"
    assert store.read_notification(WATCH_ID).state == "pending"
    with pytest.raises(OSError):
        os.fstat(read_fd)


def test_status_recovers_notification_and_rejects_orphan(
    store: WatchStore,
) -> None:
    store.create_watch(watch_record(selected_target=attached_target()), context())
    store.record_terminal(terminal())
    notification_path = store.watch_dir(WATCH_ID) / NOTIFICATION_FILENAME
    notification_path.unlink()
    assert cli._status_command(WATCH_ID)["delivery"] == "pending"

    notification_path.unlink()
    (store.watch_dir(WATCH_ID) / "terminal.json").unlink()
    notification_path.write_text("{}")
    with pytest.raises(StateError, match="without terminal"):
        cli._status_command(WATCH_ID)


def test_status_reports_lifecycle_recovered_from_terminal_truth(
    store: WatchStore,
) -> None:
    store.create_watch(watch_record(selected_target=attached_target()), context())
    store._atomic_write_json(
        store.watch_dir(WATCH_ID) / "terminal.json",
        terminal().to_dict(),
    )

    payload = cli._status_command(WATCH_ID)

    assert payload["lifecycle"] == "complete"
    assert store.read_watch(WATCH_ID).lifecycle == "complete"


@pytest.mark.parametrize(
    "state",
    ["pending", "uncertain", "blocked_uncertain", "accepted"],
)
def test_reconcile_routes_delivery_state(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    state: str,
) -> None:
    store.create_watch(watch_record(selected_target=attached_target()), context())
    current = store.record_terminal(terminal())
    if state in {"uncertain", "blocked_uncertain"}:
        current = current.mark_uncertain(sent_at=NOW, reason="lost")
        if state == "blocked_uncertain":
            current = current.mark_reconciliation_blocked(
                attempted_at=NOW,
                error="history unavailable",
            )
    elif state == "accepted":
        current = current.mark_accepted(
            accepted_at=NOW,
            rpc_method="turn/steer",
            turn_id="turn",
        )
    store.write_notification(WATCH_ID, current)
    calls: list[str] = []

    async def deliver(*_args: object, **_kwargs: object) -> NotificationRecord:
        calls.append("deliver")
        return current

    async def reconcile(*_args: object, **_kwargs: object) -> NotificationRecord:
        calls.append("reconcile")
        return current

    monkeypatch.setattr(cli, "deliver_notification", deliver)
    monkeypatch.setattr(cli, "reconcile_uncertain_delivery", reconcile)
    cli._reconcile_command(WATCH_ID)
    assert calls == (
        [] if state == "accepted" else [(state == "pending" and "deliver") or "reconcile"]
    )


def test_owned_supervisor_runs_process_to_terminal(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    process_log = tmp_path / "process.log"
    store.create_watch(
        watch_record(
            mode="run",
            lifecycle="prepared",
            selected_target=None,
            wake_on="failure",
            process_log=process_log,
        ),
        context(),
    )
    read_fd, write_fd = os.pipe()
    monkeypatch.setattr(sys, "stdin", io.StringIO(json.dumps(["/bin/sh", "-c", "printf ok"])))
    result = cli._internal_supervise_run(["--watch-id", WATCH_ID, "--handshake-fd", str(write_fd)])
    assert json.loads(os.read(read_fd, 4096)) == {"status": "active"}
    os.close(read_fd)
    assert result == cli.EXIT_SUCCESS
    assert store.read_terminal(WATCH_ID).status == "succeeded"
    assert store.read_notification(WATCH_ID).state == "none"
    assert process_log.read_text() == "ok"


def test_owned_supervisor_records_registered_target_when_spawn_fails(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    store.create_watch(
        watch_record(
            mode="run",
            lifecycle="prepared",
            selected_target=None,
            process_log=tmp_path / "process.log",
        ),
        context(),
    )
    handshake_read, handshake_write = os.pipe()
    monkeypatch.setattr(sys, "stdin", io.StringIO('["/bin/true"]'))
    delivery_calls: list[str] = []

    def fail_after_registration(
        _command: object,
        *,
        log_path: Path,
        register: Any,
    ) -> OwnedProcess:
        del log_path
        register(owned_target())
        raise StateError("gate failed")

    async def settle(
        selected_store: WatchStore,
        watch_id: str,
    ) -> NotificationRecord:
        delivery_calls.append(watch_id)
        return selected_store.read_notification(watch_id)

    monkeypatch.setattr(cli, "spawn_gated_child", fail_after_registration)
    monkeypatch.setattr(cli, "_deliver_until_settled", settle)

    result = cli._internal_supervise_run(
        ["--watch-id", WATCH_ID, "--handshake-fd", str(handshake_write)]
    )
    response = json.loads(os.read(handshake_read, 4096))
    os.close(handshake_read)

    assert result == cli.EXIT_RUNTIME_ERROR
    assert response["status"] == "error"
    assert store.read_terminal(WATCH_ID).status == "monitor_error"
    assert store.read_notification(WATCH_ID).state == "pending"
    assert delivery_calls == [WATCH_ID]


def test_owned_supervisor_discards_prepared_watch_when_spawn_fails_before_registration(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    store.create_watch(
        watch_record(
            mode="run",
            lifecycle="prepared",
            selected_target=None,
            process_log=tmp_path / "process.log",
        ),
        context(),
    )
    handshake_read, handshake_write = os.pipe()
    monkeypatch.setattr(sys, "stdin", io.StringIO('["/bin/true"]'))
    monkeypatch.setattr(
        cli,
        "spawn_gated_child",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(StateError("spawn failed")),
    )

    result = cli._internal_supervise_run(
        ["--watch-id", WATCH_ID, "--handshake-fd", str(handshake_write)]
    )
    response = json.loads(os.read(handshake_read, 4096))
    os.close(handshake_read)

    assert result == cli.EXIT_RUNTIME_ERROR
    assert response["status"] == "error"
    assert not (store.root / WATCH_ID).exists()


def test_owned_supervisor_does_not_start_second_cleanup_after_wait_failure(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    store.create_watch(
        watch_record(
            mode="run",
            lifecycle="prepared",
            selected_target=None,
            process_log=tmp_path / "process.log",
        ),
        context(),
    )
    handshake_read, handshake_write = os.pipe()
    monkeypatch.setattr(sys, "stdin", io.StringIO('["/bin/true"]'))
    selected_owned = OwnedProcess(target=owned_target())

    def spawn(
        _command: object,
        *,
        log_path: Path,
        register: Any,
    ) -> OwnedProcess:
        del log_path
        register(selected_owned.target)
        return selected_owned

    def fail_wait(*_args: object, **_kwargs: object) -> object:
        raise StateError("wait failed")

    async def settle(
        selected_store: WatchStore,
        watch_id: str,
    ) -> NotificationRecord:
        return selected_store.read_notification(watch_id)

    cleaned: list[OwnedProcess] = []
    monkeypatch.setattr(cli, "spawn_gated_child", spawn)
    monkeypatch.setattr(cli, "wait_owned_process", fail_wait)
    monkeypatch.setattr(cli, "_deliver_until_settled", settle)
    monkeypatch.setattr(
        cli,
        "terminate_owned_process",
        cleaned.append,
        raising=False,
    )

    result = cli._internal_supervise_run(
        ["--watch-id", WATCH_ID, "--handshake-fd", str(handshake_write)]
    )
    response = json.loads(os.read(handshake_read, 4096))
    os.close(handshake_read)

    assert result == cli.EXIT_RUNTIME_ERROR
    assert response == {"status": "active"}
    assert cleaned == []
    assert store.read_terminal(WATCH_ID).status == "monitor_error"


def test_owned_supervisor_does_not_signal_group_after_reaping_child(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    store.create_watch(
        watch_record(
            mode="run",
            lifecycle="prepared",
            selected_target=None,
            process_log=tmp_path / "process.log",
        ),
        context(),
    )
    handshake_read, handshake_write = os.pipe()
    monkeypatch.setattr(sys, "stdin", io.StringIO('["/bin/true"]'))
    selected_owned = OwnedProcess(target=owned_target())

    def spawn(
        _command: object,
        *,
        log_path: Path,
        register: Any,
    ) -> OwnedProcess:
        del log_path
        register(selected_owned.target)
        return selected_owned

    async def fail_after_reap(*_args: object, **_kwargs: object) -> NotificationRecord:
        raise StateError("delivery controller failed")

    cleaned: list[OwnedProcess] = []
    monkeypatch.setattr(cli, "spawn_gated_child", spawn)
    monkeypatch.setattr(
        cli,
        "wait_owned_process",
        lambda *_args, **_kwargs: OwnedProcessOutcome(
            status="succeeded",
            exit_code=0,
            signal_number=None,
        ),
    )
    monkeypatch.setattr(cli, "_deliver_until_settled", fail_after_reap)
    monkeypatch.setattr(cli, "terminate_owned_process", cleaned.append)

    result = cli._internal_supervise_run(
        ["--watch-id", WATCH_ID, "--handshake-fd", str(handshake_write)]
    )
    response = json.loads(os.read(handshake_read, 4096))
    os.close(handshake_read)

    assert result == cli.EXIT_RUNTIME_ERROR
    assert response == {"status": "active"}
    assert cleaned == []
    assert store.read_terminal(WATCH_ID).status == "succeeded"


def test_attach_supervisor_observes_readiness_without_signaling(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    store.create_watch(watch_record(selected_target=attached_target()), context())
    pidfd_read, pidfd_write = os.pipe()
    os.write(pidfd_write, b"x")
    os.close(pidfd_write)
    handshake_read, handshake_write = os.pipe()

    async def settle(
        selected_store: WatchStore,
        watch_id: str,
    ) -> NotificationRecord:
        return selected_store.read_notification(watch_id)

    monkeypatch.setattr(cli, "_deliver_until_settled", settle)
    result = cli._internal_supervise_attach(
        [
            "--watch-id",
            WATCH_ID,
            "--pidfd",
            str(pidfd_read),
            "--handshake-fd",
            str(handshake_write),
        ]
    )
    assert json.loads(os.read(handshake_read, 4096)) == {"status": "active"}
    os.close(handshake_read)
    assert result == cli.EXIT_SUCCESS
    assert store.read_terminal(WATCH_ID).status == "exited"


def test_attach_supervisor_records_monitor_failure_after_handshake(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    store.create_watch(watch_record(selected_target=attached_target()), context())
    pidfd_read, pidfd_write = os.pipe()
    handshake_read, handshake_write = os.pipe()
    delivery_calls: list[str] = []

    def fail_monitor(*_args: object, **_kwargs: object) -> str:
        raise StateError("selector failed")

    async def settle(
        selected_store: WatchStore,
        watch_id: str,
    ) -> NotificationRecord:
        delivery_calls.append(watch_id)
        return selected_store.read_notification(watch_id)

    monkeypatch.setattr(cli, "monitor_attached_process", fail_monitor)
    monkeypatch.setattr(cli, "_deliver_until_settled", settle)
    result = cli._internal_supervise_attach(
        [
            "--watch-id",
            WATCH_ID,
            "--pidfd",
            str(pidfd_read),
            "--handshake-fd",
            str(handshake_write),
        ]
    )
    assert json.loads(os.read(handshake_read, 4096)) == {"status": "active"}
    os.close(handshake_read)
    os.close(pidfd_read)
    os.close(pidfd_write)

    assert result == cli.EXIT_RUNTIME_ERROR
    assert store.read_terminal(WATCH_ID).status == "monitor_error"
    assert store.read_notification(WATCH_ID).state == "pending"
    assert delivery_calls == [WATCH_ID]


def test_supervisor_error_writes_bounded_handshake(
    store: WatchStore,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    read_fd, write_fd = os.pipe()
    monkeypatch.setattr(sys, "stdin", io.StringIO("invalid"))
    result = cli._internal_supervise_run(["--watch-id", WATCH_ID, "--handshake-fd", str(write_fd)])
    response = json.loads(os.read(read_fd, 4096))
    os.close(read_fd)
    assert result == cli.EXIT_RUNTIME_ERROR
    assert response["status"] == "error"


def test_delivery_controller_honors_retry_timer_and_terminal_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    retry = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    ).schedule_retry(
        attempted_at=NOW,
        error="offline",
        next_attempt_at=NOW,
        increment_attempt=True,
    )
    accepted = retry.mark_accepted(
        accepted_at=NOW,
        rpc_method="turn/steer",
        turn_id="turn",
    )

    class FakeStore:
        def __init__(self) -> None:
            self.current = retry

        def ensure_notification(self, _watch_id: str) -> NotificationRecord:
            return self.current

    selected_store = FakeStore()

    async def deliver(*_args: object, **_kwargs: object) -> NotificationRecord:
        selected_store.current = accepted
        return accepted

    monkeypatch.setattr(cli, "deliver_notification", deliver)
    assert (
        asyncio.run(cli._deliver_until_settled(cast(WatchStore, selected_store), WATCH_ID))
        == accepted
    )


def test_cli_helpers_validate_inputs_and_render_modes(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.delenv("CODEX_THREAD_ID", raising=False)
    with pytest.raises(cli.ExpectedProblem, match="required"):
        cli._required_thread_id()
    monkeypatch.setenv("CODEX_THREAD_ID", THREAD_ID)
    assert cli._required_thread_id() == THREAD_ID
    assert cli._selected_watch_id(WATCH_ID) == WATCH_ID
    assert cli._selected_watch_id(None) != WATCH_ID
    assert cli._validated_evidence(["/tmp/x"]) == ("/tmp/x",)

    with pytest.raises(StateError, match="invalid JSON"):
        monkeypatch.setattr(sys, "stdin", io.StringIO("{"))
        cli._read_supervisor_input()
    monkeypatch.setattr(sys, "stdin", io.StringIO("[]"))
    with pytest.raises(StateError, match="non-empty"):
        cli._read_supervisor_input()
    monkeypatch.setattr(sys, "stdin", io.StringIO('["/bin/true"]'))
    assert cli._read_supervisor_input() == ["/bin/true"]

    arguments = argparse.Namespace(
        format="text",
        color="always",
        no_color=False,
        quiet=True,
        verbose=False,
    )
    cli.render_result({"watch_id": WATCH_ID}, arguments, status="OK")
    assert "\x1b[" in capsys.readouterr().out
    arguments = argparse.Namespace(
        format="text",
        color="never",
        no_color=False,
        quiet=False,
        verbose=True,
    )
    cli.render_result(
        {"watch_id": WATCH_ID, "blocker": "unsafe", "extra": {"a": 1}},
        arguments,
        status="WARN",
    )
    output = capsys.readouterr().out
    assert "Blocker:    unsafe" in output
    assert 'extra: {"a": 1}' in output
    assert cli._payload_requires_attention({"delivery": "pending"})
    assert cli._payload_requires_attention({"delivery": "retry_due"})
    assert not cli._payload_requires_attention({"delivery": "accepted"})


def test_launch_supervisor_reads_exact_handshake_and_hides_input_from_argv() -> None:
    script = (
        "import json,os,sys;"
        "payload=json.load(sys.stdin);"
        "fd=int(sys.argv[-1]);"
        "os.write(fd,json.dumps({'status':'active','input':payload}).encode())"
    )
    result = cli._launch_supervisor(
        [sys.executable, "-c", script],
        input_payload=["secret"],
    )
    assert result == {"status": "active", "input": ["secret"]}


@pytest.mark.parametrize("failure_operation", ["write", "close"])
def test_launch_supervisor_input_failure_cleans_process_and_pipe(
    monkeypatch: pytest.MonkeyPatch,
    failure_operation: str,
) -> None:
    pipe_fds: tuple[int, int] | None = None
    closed_fds: set[int] = set()
    terminated: list[object] = []
    original_pipe = os.pipe
    original_close = os.close

    class FailingInput:
        def write(self, _payload: str) -> int:
            if failure_operation == "write":
                raise OSError("write failed")
            return 1

        def close(self) -> None:
            if failure_operation == "close":
                raise OSError("close failed")

    class FakeProcess:
        pid = 4242
        stdin = FailingInput()

    def tracked_pipe() -> tuple[int, int]:
        nonlocal pipe_fds
        pipe_fds = original_pipe()
        return pipe_fds

    def tracked_close(file_descriptor: int) -> None:
        closed_fds.add(file_descriptor)
        original_close(file_descriptor)

    monkeypatch.setattr(os, "pipe", tracked_pipe)
    monkeypatch.setattr(os, "close", tracked_close)
    monkeypatch.setattr(subprocess, "Popen", lambda *_args, **_kwargs: FakeProcess())
    monkeypatch.setattr(cli, "_terminate_supervisor_process", terminated.append)

    try:
        with pytest.raises(StateError, match="supervisor input"):
            cli._launch_supervisor(
                [sys.executable, "-c", "pass"],
                input_payload=["command"],
            )
    finally:
        if pipe_fds is not None:
            for file_descriptor in pipe_fds:
                if file_descriptor not in closed_fds:
                    original_close(file_descriptor)

    assert pipe_fds is not None
    assert closed_fds == set(pipe_fds)
    assert len(terminated) == 1


@pytest.mark.parametrize("term_exits", [True, False])
def test_launch_supervisor_timeout_cleans_and_reaps_process_group(
    monkeypatch: pytest.MonkeyPatch,
    term_exits: bool,
) -> None:
    sent_signals: list[int] = []
    wait_timeouts: list[float | None] = []

    class FakeProcess:
        pid = 4242
        stdin = None

        def terminate(self) -> None:
            pass

        def kill(self) -> None:
            pass

        def wait(self, timeout: float | None = None) -> int:
            wait_timeouts.append(timeout)
            if not term_exits and len(wait_timeouts) == 1:
                raise subprocess.TimeoutExpired("supervisor", timeout or 0.0)
            return 0

    class FakeSelector:
        def register(self, *_args: object) -> None:
            pass

        def select(self, _timeout: float) -> list[object]:
            return []

        def close(self) -> None:
            pass

    monkeypatch.setattr(subprocess, "Popen", lambda *_args, **_kwargs: FakeProcess())
    monkeypatch.setattr(selectors, "DefaultSelector", FakeSelector)
    monkeypatch.setattr(
        os,
        "killpg",
        lambda _process_group, signal_number: sent_signals.append(signal_number),
    )

    with pytest.raises(StateError, match="did not confirm"):
        cli._launch_supervisor([sys.executable, "-c", "pass"])

    assert sent_signals == [signal.SIGTERM, signal.SIGKILL]
    assert wait_timeouts == (
        [cli.SUPERVISOR_SHUTDOWN_GRACE_SECONDS]
        if term_exits
        else [cli.SUPERVISOR_SHUTDOWN_GRACE_SECONDS, None]
    )


def test_monitor_error_is_recorded_only_for_exact_targets(store: WatchStore) -> None:
    store.create_watch(watch_record(selected_target=attached_target()), context())
    cli._record_monitor_error(store, WATCH_ID, object(), "ignored")
    assert not (store.watch_dir(WATCH_ID) / "terminal.json").exists()
    cli._record_monitor_error(store, WATCH_ID, attached_target(), "failed")
    assert store.read_terminal(WATCH_ID).status == "monitor_error"


def test_supervisor_signal_handler_converts_termination_for_cleanup() -> None:
    previous = cli._install_supervisor_signal_handlers()
    try:
        with pytest.raises(cli.SupervisorInterrupted, match="SIGTERM"):
            os.kill(os.getpid(), signal.SIGTERM)
    finally:
        cli._restore_signal_handlers(previous)
