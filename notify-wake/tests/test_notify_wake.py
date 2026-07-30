from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from random import Random
from typing import Any, cast

import pytest
from notify_wake.app_server import (
    AppServerError,
    MessageTransport,
    RpcClient,
    UnixWebSocketTransport,
    _accepted_from_ledger,
    _connect,
    _decode_message,
    _effective_context_from_resume,
    _find_client_message,
    _run_daemon_version,
    _sanitize_error_text,
    _thread_from_result,
    build_wake_prompt,
    capture_wake_context,
    capture_wake_context_from_daemon,
    capture_wake_readiness,
    capture_wake_readiness_from_daemon,
    deliver_notification,
    discover_daemon_socket,
    initialize_params,
    reconcile_uncertain_delivery,
)
from notify_wake.cli import build_parser, render_result
from notify_wake.models import (
    MAX_DELIVERY_ATTEMPTS,
    SCHEMA_VERSION,
    NotificationRecord,
    NotifyWaitLease,
    TargetIdentity,
    TerminalRecord,
    TerminalStatus,
    WakeContext,
    WatchRecord,
    earliest_retry_at,
    notification_is_due,
)
from notify_wake.processes import (
    capture_attached_process,
    monitor_attached_process,
    parse_proc_stat_start_ticks,
    pidfd_supported,
)
from notify_wake.state import StateError, WatchStore
from websockets.asyncio.server import unix_serve

NOW = datetime(2026, 7, 28, 18, 0, tzinfo=UTC)
THREAD_ID = "019fa9c6-3613-7e60-a328-bf6f5c62c7bd"
WATCH_ID = "12345678-1234-5678-9234-567812345678"
EVENT_ID = "22345678-1234-5678-9234-567812345678"
PERMISSION_PROFILE = ":danger-full-access"
APPROVAL_POLICY = "never"
ACTIVE_TURN_ID = "active-turn"
TARGET_PID = 4242
TARGET_START_TICKS = 987654
TIMEOUT_SECONDS = 120.0


def run(coroutine: Any) -> Any:
    return asyncio.run(coroutine)


class ScriptedTransport:
    def __init__(
        self,
        handler: Callable[[dict[str, Any]], list[dict[str, Any]]],
        *,
        fail_after_wake_send: bool = False,
    ) -> None:
        self._handler = handler
        self._responses: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self._fail_after_wake_send = fail_after_wake_send
        self.sent: list[dict[str, Any]] = []
        self.closed = False

    async def send(self, message: dict[str, Any]) -> None:
        self.sent.append(message)
        for response in self._handler(message):
            self._responses.put_nowait(response)
        if self._fail_after_wake_send and message.get("method") == "turn/steer":
            raise ConnectionError("simulated lost wake acknowledgment")

    async def receive(self) -> dict[str, Any]:
        return await self._responses.get()

    async def close(self) -> None:
        self.closed = True


class ReaderFailureTransport:
    def __init__(
        self,
        handler: Callable[[dict[str, Any]], list[dict[str, Any]]],
    ) -> None:
        self._handler = handler
        self._responses: asyncio.Queue[dict[str, Any] | BaseException] = asyncio.Queue()
        self.sent: list[dict[str, Any]] = []
        self.closed = False

    async def send(self, message: dict[str, Any]) -> None:
        self.sent.append(message)
        if message.get("method") == "turn/steer":
            self._responses.put_nowait(ConnectionError("response reader disconnected"))
            return
        for response in self._handler(message):
            self._responses.put_nowait(response)

    async def receive(self) -> dict[str, Any]:
        response = await self._responses.get()
        if isinstance(response, BaseException):
            raise response
        return response

    async def close(self) -> None:
        self.closed = True


class FailAfterMethodTransport(ScriptedTransport):
    def __init__(
        self,
        handler: Callable[[dict[str, Any]], list[dict[str, Any]]],
        *,
        method: str,
    ) -> None:
        super().__init__(handler)
        self._method = method

    async def send(self, message: dict[str, Any]) -> None:
        await super().send(message)
        if message.get("method") == self._method:
            raise ConnectionError(f"lost {self._method} acknowledgment")


def app_server_handler(
    *,
    permission_profile: str | None = PERMISSION_PROFILE,
    approval_policy: object = APPROVAL_POLICY,
    thread_status: str = "active",
    turns: list[dict[str, Any]] | None = None,
    goal: dict[str, Any] | None = None,
    history_client_id: str | None = None,
    complete_history: bool = True,
) -> Callable[[dict[str, Any]], list[dict[str, Any]]]:
    selected_turns = (
        [{"id": ACTIVE_TURN_ID, "status": "inProgress", "items": []}] if turns is None else turns
    )
    experimental_api = False

    def handle(message: dict[str, Any]) -> list[dict[str, Any]]:
        nonlocal experimental_api
        if "id" not in message:
            return []
        request_id = message["id"]
        method = message.get("method")
        if method == "initialize":
            experimental_api = (
                message["params"].get("capabilities", {}).get("experimentalApi") is True
            )
            return [{"id": request_id, "result": {"userAgent": "fake"}}]
        if method == "thread/resume":
            if message["params"].get("permissions") is not None and not experimental_api:
                return [
                    {
                        "id": request_id,
                        "error": {
                            "code": -32600,
                            "message": "permissions require experimentalApi",
                        },
                    }
                ]
            return [
                {
                    "id": request_id,
                    "result": {
                        "thread": {
                            "id": THREAD_ID,
                            "status": {"type": thread_status},
                            "turns": selected_turns,
                        },
                        "activePermissionProfile": (
                            {"id": permission_profile} if permission_profile is not None else None
                        ),
                        "approvalPolicy": approval_policy,
                    },
                }
            ]
        if method == "thread/goal/get":
            return [{"id": request_id, "result": {"goal": goal}}]
        if method == "thread/read":
            history_turns = [dict(turn) for turn in selected_turns]
            if history_client_id is not None:
                history_turns = [
                    {
                        "id": ACTIVE_TURN_ID,
                        "status": "completed",
                        "items": [
                            {
                                "type": "userMessage",
                                "clientId": history_client_id,
                                "content": [],
                            }
                        ],
                    }
                ]
            elif not complete_history:
                history_turns = [{"id": ACTIVE_TURN_ID, "status": "completed"}]
            return [
                {
                    "id": request_id,
                    "result": {
                        "thread": {
                            "id": THREAD_ID,
                            "status": {"type": thread_status},
                            "turns": history_turns,
                        }
                    },
                }
            ]
        if method == "turn/steer":
            return [{"id": request_id, "result": {"turnId": ACTIVE_TURN_ID}}]
        if method == "turn/start":
            return [
                {
                    "id": request_id,
                    "result": {"turn": {"id": "unsafe-idle-turn"}},
                }
            ]
        if method == "thread/goal/set":
            return [{"id": request_id, "result": {"goal": goal}}]
        raise AssertionError(f"unexpected method: {method}")

    return handle


def wake_context(*, goal_snapshot: dict[str, Any] | None = None) -> WakeContext:
    return WakeContext(
        thread_id=THREAD_ID,
        permission_profile=PERMISSION_PROFILE,
        approval_policy=APPROVAL_POLICY,
        captured_at=NOW,
        goal_snapshot=goal_snapshot,
    )


def target_identity(*, pid: int = TARGET_PID) -> TargetIdentity:
    return TargetIdentity(
        kind="attached",
        pid=pid,
        process_group_id=None,
        start_ticks=TARGET_START_TICKS,
        identity_method="linux-pidfd",
    )


def watch_record(*, watch_id: str = WATCH_ID) -> WatchRecord:
    return WatchRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=watch_id,
        mode="attach",
        lifecycle="active",
        created_at=NOW,
        updated_at=NOW,
        timeout_seconds=TIMEOUT_SECONDS,
        wake_on="always",
        evidence_paths=("/tmp/evidence.json",),
        process_log_path=None,
        target=target_identity(),
    )


def terminal_record(
    *,
    attention_required: bool = True,
    status: TerminalStatus = "exited",
) -> TerminalRecord:
    return TerminalRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        target=target_identity(),
        status=status,
        exit_code=None,
        signal_number=None,
        occurred_at=NOW,
        attention_required=attention_required,
        evidence_paths=("/tmp/evidence.json",),
    )


def prepared_store(tmp_path: Path) -> WatchStore:
    store = WatchStore(tmp_path / "codex-home" / "notify-wake")
    store.initialize()
    store.create_watch(watch_record(), wake_context())
    store.record_terminal(terminal_record())
    return store


def test_store_uses_exact_registered_root_and_rejects_broad_or_symlinked_paths(
    tmp_path: Path,
) -> None:
    store = WatchStore(tmp_path / "codex-home" / "notify-wake")
    store.initialize()

    marker = store.root / ".notify-wake-root.json"
    assert marker.is_file()
    assert json.loads(marker.read_text(encoding="utf-8"))["root_path"] == str(store.root.resolve())

    with pytest.raises(StateError, match="canonical UUID"):
        store.watch_dir("latest")

    outside = tmp_path / "outside"
    outside.mkdir()
    (store.root / WATCH_ID).symlink_to(outside, target_is_directory=True)
    with pytest.raises(StateError, match="symlink"):
        store.watch_dir(WATCH_ID)


def test_terminal_truth_survives_notification_write_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    store = WatchStore(tmp_path / "codex-home" / "notify-wake")
    store.initialize()
    store.create_watch(watch_record(), wake_context())
    original_write = store._atomic_write_json

    def fail_notification(path: Path, payload: dict[str, object]) -> None:
        if path.name == "notification.json":
            raise OSError("simulated notification failure")
        original_write(path, payload)

    monkeypatch.setattr(store, "_atomic_write_json", fail_notification)

    with pytest.raises(OSError, match="notification failure"):
        store.record_terminal(terminal_record())

    persisted = store.read_terminal(WATCH_ID)
    assert persisted.status == "exited"
    assert not (store.watch_dir(WATCH_ID) / "notification.json").exists()


def test_capture_discovers_implicit_permission_profile_and_advertises_capability() -> None:
    transport = ScriptedTransport(app_server_handler())

    context = run(
        capture_wake_context(
            thread_id=THREAD_ID,
            requested_permission_profile=None,
            transport=transport,
            captured_at=NOW,
        )
    )

    assert context.permission_profile == PERMISSION_PROFILE
    initialize = next(
        message for message in transport.sent if message.get("method") == "initialize"
    )
    assert initialize["params"]["capabilities"] == {"experimentalApi": True}
    resume = next(message for message in transport.sent if message.get("method") == "thread/resume")
    assert resume["params"] == {"threadId": THREAD_ID}


def test_capture_rejects_null_profile_before_launch() -> None:
    transport = ScriptedTransport(app_server_handler(permission_profile=None))

    with pytest.raises(AppServerError, match="selectable effective permission profile") as error:
        run(
            capture_wake_context(
                thread_id=THREAD_ID,
                requested_permission_profile=None,
                transport=transport,
                captured_at=NOW,
            )
        )

    assert error.value.permanent


def test_capture_preserves_granular_approval_policy() -> None:
    policy = {
        "granular": {
            "mcp_elicitations": True,
            "request_permissions": False,
            "rules": True,
            "sandbox_approval": False,
            "skill_approval": True,
        }
    }
    transport = ScriptedTransport(app_server_handler(approval_policy=policy))

    context = run(
        capture_wake_context(
            thread_id=THREAD_ID,
            requested_permission_profile=PERMISSION_PROFILE,
            transport=transport,
            captured_at=NOW,
        )
    )

    assert context.approval_policy == policy
    assert context.resume_params()["approvalPolicy"] == policy


def test_delivery_blocks_goal_without_mutation(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    goal = {"status": "blocked", "objective": "wait for process"}
    transport = ScriptedTransport(app_server_handler(goal=goal))

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "blocked"
    assert "goal" in (result.last_error or "")
    assert not any(
        message.get("method") in {"thread/goal/set", "turn/start", "turn/steer"}
        for message in transport.sent
    )
    assert store.read_terminal(WATCH_ID).status == "exited"


def test_default_delivery_starts_idle_thread_without_model_override(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    transport = ScriptedTransport(app_server_handler(thread_status="idle", turns=[]))

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "accepted"
    start = next(message for message in transport.sent if message.get("method") == "turn/start")
    assert "model" not in start["params"]
    assert "effort" not in start["params"]


def test_delivery_steers_exact_active_turn_and_persists_acceptance(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    transport = ScriptedTransport(app_server_handler())

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "accepted"
    assert result.accepted_rpc_method == "turn/steer"
    assert result.accepted_turn_id == ACTIVE_TURN_ID
    steer = next(message for message in transport.sent if message.get("method") == "turn/steer")
    assert steer["params"]["expectedTurnId"] == ACTIVE_TURN_ID
    assert steer["params"]["clientUserMessageId"] == EVENT_ID
    assert store.read_watch(WATCH_ID).lifecycle == "closed"


def test_goal_activation_uncertainty_blocks_without_wake_reconciliation(
    tmp_path: Path,
) -> None:
    store = prepared_store(tmp_path)
    current_goal = {
        "threadId": THREAD_ID,
        "objective": "wait for the registered research controller",
        "status": "blocked",
        "tokenBudget": 100_000,
        "tokensUsed": 1_000,
        "timeUsedSeconds": 20,
        "createdAt": 10,
        "updatedAt": 21,
    }
    owned = NotifyWaitLease.owned(
        lease_id="32345678-1234-5678-9234-567812345678",
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=current_goal,
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    store.write_goal_wait_lease(WATCH_ID, owned)
    base_handler = app_server_handler(thread_status="idle", turns=[], goal=current_goal)

    def stateful_handler(message: dict[str, Any]) -> list[dict[str, Any]]:
        nonlocal current_goal
        if message.get("method") == "thread/goal/get":
            return [{"id": message["id"], "result": {"goal": current_goal}}]
        if message.get("method") == "thread/goal/set":
            current_goal = {
                **current_goal,
                "status": message["params"]["status"],
                "updatedAt": current_goal["updatedAt"] + 1,
            }
            return [{"id": message["id"], "result": {"goal": current_goal}}]
        return base_handler(message)

    transport = FailAfterMethodTransport(
        stateful_handler,
        method="thread/goal/set",
    )

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "blocked"
    assert result.attempted_rpc_method is None
    assert result.request_sent_at is None
    assert "goal activation" in (result.last_error or "")
    persisted_lease = store.read_goal_wait_lease(WATCH_ID)
    assert persisted_lease is not None
    assert persisted_lease.state == "uncertain"
    assert not any(
        message.get("method") in {"turn/start", "turn/steer"} for message in transport.sent
    )


def test_lost_acknowledgment_is_uncertain_then_reconciled_by_client_id(
    tmp_path: Path,
) -> None:
    store = prepared_store(tmp_path)
    lost_transport = ScriptedTransport(
        app_server_handler(),
        fail_after_wake_send=True,
    )

    uncertain = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: lost_transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert uncertain.state == "uncertain"
    assert uncertain.request_sent_at == NOW

    history_transport = ScriptedTransport(app_server_handler(history_client_id=EVENT_ID))
    accepted = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: history_transport,
            now=lambda: NOW + timedelta(seconds=1),
            random=Random(0),
        )
    )

    assert accepted.state == "accepted"
    assert accepted.accepted_turn_id == ACTIVE_TURN_ID


def test_reader_failure_after_wake_send_is_durably_uncertain(
    tmp_path: Path,
) -> None:
    store = prepared_store(tmp_path)
    transport = ReaderFailureTransport(app_server_handler())

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "uncertain"
    assert result.request_sent_at == NOW
    assert "response reader disconnected" in (result.last_error or "")


def test_incomplete_history_blocks_uncertain_delivery_without_retry(
    tmp_path: Path,
) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost response"),
    )
    transport = ScriptedTransport(app_server_handler(complete_history=False))

    result = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW + timedelta(seconds=1),
            random=Random(0),
        )
    )

    assert result.state == "blocked"
    assert "history" in (result.last_error or "")
    assert result.attempt_count == 1


@pytest.mark.parametrize(
    "malformed_item",
    ["malformed", {}, {"type": "userMessage"}],
)
def test_malformed_history_item_blocks_uncertain_delivery_without_retry(
    tmp_path: Path,
    malformed_item: object,
) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost response"),
    )
    transport = ScriptedTransport(
        app_server_handler(
            turns=[
                {
                    "id": ACTIVE_TURN_ID,
                    "status": "completed",
                    "items": [malformed_item],
                }
            ],
        )
    )

    result = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW + timedelta(seconds=1),
            random=Random(0),
        )
    )

    assert result.state == "blocked"
    assert "history" in (result.last_error or "")
    assert result.attempt_count == 1


def test_retry_deadlines_are_per_event_and_do_not_suppress_fresh_events() -> None:
    fresh = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )
    backed_off = replace(
        fresh,
        watch_id="32345678-1234-5678-9234-567812345678",
        event_id="42345678-1234-5678-9234-567812345678",
    ).schedule_retry(
        attempted_at=NOW,
        error="temporary transport error",
        next_attempt_at=NOW + timedelta(minutes=5),
        increment_attempt=True,
    )

    assert notification_is_due(fresh, NOW)
    assert not notification_is_due(backed_off, NOW)
    assert earliest_retry_at((backed_off, fresh)) == NOW + timedelta(minutes=5)


def test_retry_exhaustion_blocks_only_the_selected_event() -> None:
    event = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )
    for attempt in range(MAX_DELIVERY_ATTEMPTS):
        event = event.schedule_retry(
            attempted_at=NOW + timedelta(seconds=attempt),
            error="temporary transport error",
            next_attempt_at=NOW + timedelta(seconds=attempt + 1),
            increment_attempt=True,
        )

    assert event.state == "blocked"
    assert event.next_attempt_at is None


def test_daemon_discovery_uses_version_command_not_proxy(tmp_path: Path) -> None:
    socket_path = tmp_path / "app-server.sock"
    socket_path.touch()
    commands: list[tuple[str, ...]] = []

    def runner(command: tuple[str, ...]) -> subprocess.CompletedProcess[str]:
        commands.append(command)
        return subprocess.CompletedProcess(
            command,
            0,
            stdout=json.dumps(
                {
                    "status": "running",
                    "socketPath": str(socket_path),
                    "appServerVersion": "0.146.0",
                }
            ),
            stderr="",
        )

    discovered = discover_daemon_socket(runner=runner)

    assert discovered == socket_path
    assert commands == [("codex", "app-server", "daemon", "version")]
    assert all("proxy" not in command for command in commands)


def test_proc_stat_parser_handles_spaces_and_parentheses_in_process_name() -> None:
    stat = "4242 (worker (phase one)) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 987654 20"

    assert parse_proc_stat_start_ticks(stat) == TARGET_START_TICKS


def test_attach_rejects_pid_reuse_between_identity_reads() -> None:
    reads = iter((TARGET_START_TICKS, TARGET_START_TICKS + 1))
    closed: list[int] = []

    with pytest.raises(StateError, match="identity changed"):
        capture_attached_process(
            TARGET_PID,
            expected_start_ticks=None,
            pidfd_open=lambda _pid: 9,
            start_ticks_reader=lambda _pid: next(reads),
            close_fd=closed.append,
        )

    assert closed == [9]


@pytest.mark.skipif(
    not pidfd_supported(),
    reason="pidfd monitoring is Linux-only",
)
def test_attached_timeout_never_terminates_target() -> None:
    process = subprocess.Popen(
        [sys.executable, "-c", "import time; time.sleep(10)"],
        start_new_session=True,
    )
    try:
        attached = capture_attached_process(
            process.pid,
            expected_start_ticks=None,
        )
        outcome = monitor_attached_process(attached, timeout_seconds=0.05)

        assert outcome == "timed_out"
        assert process.poll() is None
    finally:
        os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=5)


def test_cli_contract_rejects_conflicting_verbosity_and_requires_timeout() -> None:
    parser = build_parser()

    with pytest.raises(SystemExit) as verbosity_error:
        parser.parse_args(["status", WATCH_ID, "--quiet", "--verbose"])
    assert verbosity_error.value.code == 2

    with pytest.raises(SystemExit) as timeout_error:
        parser.parse_args(["attach", "--pid", str(TARGET_PID)])
    assert timeout_error.value.code == 2


def test_text_and_json_rendering_have_same_primary_fields(
    capsys: pytest.CaptureFixture[str],
) -> None:
    payload = {
        "watch_id": WATCH_ID,
        "lifecycle": "active",
        "delivery": "pending",
        "attention_required": False,
        "state_path": f"/tmp/{WATCH_ID}",
        "blocker": None,
    }
    text_arguments = argparse.Namespace(
        format="text",
        color="never",
        no_color=False,
        quiet=False,
        verbose=False,
    )
    json_arguments = replace_namespace(text_arguments, format="json")

    render_result(payload, text_arguments, status="OK")
    text_output = capsys.readouterr()
    render_result(payload, json_arguments, status="OK")
    json_output = capsys.readouterr()

    assert WATCH_ID in text_output.out
    assert text_output.err == ""
    assert json.loads(json_output.out) == payload
    assert json_output.err == ""


def replace_namespace(
    namespace: argparse.Namespace,
    **changes: object,
) -> argparse.Namespace:
    return argparse.Namespace(**{**vars(namespace), **changes})


@pytest.mark.parametrize("initial_state", ["accepted", "none", "blocked"])
def test_terminal_delivery_states_do_not_connect(
    tmp_path: Path,
    initial_state: str,
) -> None:
    store = prepared_store(tmp_path)
    current = store.read_notification(WATCH_ID)
    if initial_state == "accepted":
        selected = current.mark_accepted(
            accepted_at=NOW,
            rpc_method="turn/steer",
            turn_id=ACTIVE_TURN_ID,
        )
    elif initial_state == "blocked":
        selected = current.mark_blocked(attempted_at=NOW, error="unsafe")
    else:
        selected = NotificationRecord.pending(
            watch_id=WATCH_ID,
            event_id=EVENT_ID,
            thread_id=THREAD_ID,
            attention_required=False,
        )
    store.write_notification(WATCH_ID, selected)

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: (_ for _ in ()).throw(AssertionError("must not connect")),
            now=lambda: NOW,
        )
    )
    assert result.state == initial_state


def test_future_retry_deadline_does_not_connect(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    retry = store.read_notification(WATCH_ID).schedule_retry(
        attempted_at=NOW,
        error="offline",
        next_attempt_at=NOW + timedelta(seconds=5),
        increment_attempt=True,
    )
    store.write_notification(WATCH_ID, retry)

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: (_ for _ in ()).throw(AssertionError("must not connect")),
            now=lambda: NOW,
        )
    )
    assert result == retry


def test_connection_failure_schedules_per_event_retry(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)

    def fail_connect() -> MessageTransport:
        raise OSError("daemon restarting")

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            fail_connect,
            now=lambda: NOW,
            random=Random(0),
        )
    )
    assert result.state == "retry_due"
    assert result.attempt_count == 1
    assert result.next_attempt_at is not None
    assert result.next_attempt_at <= NOW + timedelta(seconds=5)


@pytest.mark.parametrize(
    ("profile", "policy", "message"),
    [
        ("different", APPROVAL_POLICY, "permission profile mismatch"),
        (PERMISSION_PROFILE, "on-request", "approval policy mismatch"),
    ],
)
def test_restart_context_mismatch_is_permanently_blocked(
    tmp_path: Path,
    profile: str,
    policy: object,
    message: str,
) -> None:
    store = prepared_store(tmp_path)
    transport = ScriptedTransport(
        app_server_handler(permission_profile=profile, approval_policy=policy)
    )

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
        )
    )
    assert result.state == "blocked"
    assert message in (result.last_error or "")


@pytest.mark.parametrize(
    ("thread_status", "turns", "message"),
    [
        ("paused", [], "not deliverable"),
        ("active", [], "exactly one"),
        (
            "active",
            [
                {"id": "one", "status": "inProgress", "items": []},
                {"id": "two", "status": "inProgress", "items": []},
            ],
            "exactly one",
        ),
    ],
)
def test_delivery_blocks_unknown_or_ambiguous_active_state(
    tmp_path: Path,
    thread_status: str,
    turns: list[dict[str, Any]],
    message: str,
) -> None:
    store = prepared_store(tmp_path)
    transport = ScriptedTransport(app_server_handler(thread_status=thread_status, turns=turns))
    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
            random=Random(0),
        )
    )
    assert result.state == "retry_due"
    assert message in (result.last_error or "")


def test_reconcile_absent_complete_history_becomes_retry_due(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost ack"),
    )
    result = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: ScriptedTransport(app_server_handler()),
            now=lambda: NOW + timedelta(seconds=1),
            random=Random(0),
        )
    )
    assert result.state == "retry_due"
    assert result.attempt_count == 1


def test_reconcile_transport_failure_schedules_history_retry(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost ack"),
    )
    result = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: (_ for _ in ()).throw(OSError("offline")),
            now=lambda: NOW,
            random=Random(0),
        )
    )
    assert result.state == "retry_due"
    assert "reconciliation unavailable" in (result.last_error or "")
    assert result.request_sent_at == NOW
    assert result.uncertainty_reason == "lost ack"
    assert result.attempt_count == 2
    assert result.next_attempt_at is not None
    assert result.next_attempt_at > NOW

    accepted = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: ScriptedTransport(app_server_handler(history_client_id=EVENT_ID)),
            now=lambda: NOW + timedelta(seconds=1),
        )
    )
    assert accepted.state == "accepted"
    assert accepted.accepted_turn_id == ACTIVE_TURN_ID


def test_reconcile_transport_failures_exhaust_attempt_limit(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost ack"),
    )

    result: NotificationRecord | None = None
    for attempt in range(MAX_DELIVERY_ATTEMPTS - 1):
        attempted_at = NOW + timedelta(minutes=10 * attempt)
        result = run(
            reconcile_uncertain_delivery(
                store,
                WATCH_ID,
                lambda: (_ for _ in ()).throw(OSError("offline")),
                now=lambda attempted_at=attempted_at: attempted_at,
                random=Random(0),
            )
        )

    assert result is not None
    assert result.state == "blocked"
    assert result.attempt_count == MAX_DELIVERY_ATTEMPTS
    assert result.request_sent_at == NOW
    assert result.uncertainty_reason == "lost ack"
    assert result.next_attempt_at is None


def test_reconcile_authority_mismatch_is_permanently_blocked(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost ack"),
    )

    result = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: ScriptedTransport(app_server_handler(permission_profile="different")),
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "blocked"
    assert result.attempt_count == 1
    assert result.request_sent_at == NOW
    assert result.uncertainty_reason == "lost ack"
    assert "permission profile mismatch" in (result.last_error or "")


def test_explicit_wake_rejection_is_retryable_not_uncertain(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    base = app_server_handler()

    def reject_steer(message: dict[str, Any]) -> list[dict[str, Any]]:
        if message.get("method") == "turn/steer":
            return [
                {
                    "id": message["id"],
                    "error": {"code": -32001, "message": "stale active turn"},
                }
            ]
        return base(message)

    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: ScriptedTransport(reject_steer),
            now=lambda: NOW,
            random=Random(0),
        )
    )

    assert result.state == "retry_due"
    assert result.attempt_count == 1
    assert result.request_sent_at is None
    assert "stale active turn" in (result.last_error or "")


def test_explicit_wake_rejections_exhaust_send_attempt_limit(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    base = app_server_handler()

    def reject_steer(message: dict[str, Any]) -> list[dict[str, Any]]:
        if message.get("method") == "turn/steer":
            return [
                {
                    "id": message["id"],
                    "error": {"code": -32602, "message": "invalid parameters"},
                }
            ]
        return base(message)

    result: NotificationRecord | None = None
    for attempt in range(MAX_DELIVERY_ATTEMPTS):
        attempted_at = NOW + timedelta(minutes=10 * attempt)
        result = run(
            deliver_notification(
                store,
                WATCH_ID,
                lambda: ScriptedTransport(reject_steer),
                now=lambda attempted_at=attempted_at: attempted_at,
                random=Random(0),
            )
        )

    assert result is not None
    assert result.state == "blocked"
    assert result.attempt_count == MAX_DELIVERY_ATTEMPTS
    assert result.next_attempt_at is None


def test_accepted_ledger_prevents_duplicate_delivery(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    with store.thread_lock(THREAD_ID) as lock_path:
        store.write_accepted_ledger(
            lock_path,
            THREAD_ID,
            {
                EVENT_ID: {
                    "accepted_at": NOW.isoformat(),
                    "rpc_method": "turn/steer",
                    "turn_id": ACTIVE_TURN_ID,
                }
            },
        )
    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: (_ for _ in ()).throw(AssertionError("duplicate send")),
            now=lambda: NOW,
        )
    )
    assert result.state == "accepted"
    assert store.read_watch(WATCH_ID).lifecycle == "closed"


def test_concurrent_same_thread_delivery_accepts_one_wake(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    transports: list[ScriptedTransport] = []

    def connect() -> MessageTransport:
        transport = ScriptedTransport(app_server_handler())
        transports.append(transport)
        return transport

    async def deliver_both() -> tuple[NotificationRecord, NotificationRecord]:
        return await asyncio.gather(
            deliver_notification(store, WATCH_ID, connect, now=lambda: NOW),
            deliver_notification(store, WATCH_ID, connect, now=lambda: NOW),
        )

    results = run(asyncio.wait_for(deliver_both(), timeout=2))
    assert [result.state for result in results] == ["accepted", "accepted"]
    assert (
        sum(
            message.get("method") == "turn/steer"
            for transport in transports
            for message in transport.sent
        )
        == 1
    )


def test_concurrent_same_event_delivery_does_not_resend_uncertain_wake(
    tmp_path: Path,
) -> None:
    store = prepared_store(tmp_path)
    transports: list[ScriptedTransport] = []

    def connect() -> MessageTransport:
        transport = ScriptedTransport(
            app_server_handler(),
            fail_after_wake_send=True,
        )
        transports.append(transport)
        return transport

    async def deliver_both() -> tuple[NotificationRecord, NotificationRecord]:
        return await asyncio.gather(
            deliver_notification(store, WATCH_ID, connect, now=lambda: NOW),
            deliver_notification(store, WATCH_ID, connect, now=lambda: NOW),
        )

    results = run(asyncio.wait_for(deliver_both(), timeout=2))

    assert [result.state for result in results] == ["uncertain", "uncertain"]
    assert len(transports) == 1
    assert (
        sum(
            message.get("method") == "turn/steer"
            for transport in transports
            for message in transport.sent
        )
        == 1
    )


@pytest.mark.parametrize(
    ("result", "message"),
    [
        (subprocess.CompletedProcess((), 1, "", "failure\nsecret"), "failure secret"),
        (subprocess.CompletedProcess((), 0, "{", ""), "invalid JSON"),
        (subprocess.CompletedProcess((), 0, "[]", ""), "not running"),
        (
            subprocess.CompletedProcess((), 0, '{"status":"stopped"}', ""),
            "not running",
        ),
        (
            subprocess.CompletedProcess((), 0, '{"status":"running","socketPath":"relative"}', ""),
            "absolute socket",
        ),
        (
            subprocess.CompletedProcess(
                (),
                0,
                '{"status":"running","socketPath":"/tmp/app.sock"}',
                "",
            ),
            "appServerVersion",
        ),
        (
            subprocess.CompletedProcess(
                (),
                0,
                ('{"status":"running","socketPath":"/tmp/app.sock","appServerVersion":"0.145.0"}'),
                "",
            ),
            "cutover required",
        ),
    ],
)
def test_daemon_discovery_rejects_invalid_status(
    result: subprocess.CompletedProcess[str],
    message: str,
) -> None:
    with pytest.raises(AppServerError, match=message):
        discover_daemon_socket(runner=lambda _command: result)


def test_capture_rejects_requested_profile_mismatch_and_invalid_goal() -> None:
    mismatch = ScriptedTransport(app_server_handler(permission_profile="different"))
    with pytest.raises(AppServerError, match="mismatch"):
        run(
            capture_wake_context(
                thread_id=THREAD_ID,
                requested_permission_profile=PERMISSION_PROFILE,
                transport=mismatch,
                captured_at=NOW,
            )
        )

    base = app_server_handler()

    def invalid_goal(message: dict[str, Any]) -> list[dict[str, Any]]:
        if message.get("method") == "thread/goal/get":
            return [{"id": message["id"], "result": {"goal": "invalid"}}]
        return base(message)

    with pytest.raises(AppServerError, match="invalid goal"):
        run(
            capture_wake_context(
                thread_id=THREAD_ID,
                requested_permission_profile=None,
                transport=ScriptedTransport(invalid_goal),
                captured_at=NOW,
            )
        )


def test_rpc_rejects_server_requests() -> None:
    requests: list[dict[str, Any]] = []

    def handler(message: dict[str, Any]) -> list[dict[str, Any]]:
        if message.get("method") == "ping":
            return [
                {"id": "approval-1", "method": "item/commandExecution/requestApproval"},
                {"id": message["id"], "result": {"ok": True}},
            ]
        if "error" in message:
            requests.append(message)
        return []

    async def scenario() -> None:
        async with RpcClient(ScriptedTransport(handler), request_timeout=0.1) as client:
            assert await client.request("ping", {}) == {"ok": True}
            await asyncio.sleep(0)

    run(scenario())
    assert requests[0]["error"]["code"] == -32601


def test_rpc_timeout_error_and_nonobject_results() -> None:
    async def timeout() -> None:
        async with RpcClient(
            ScriptedTransport(lambda _message: []),
            request_timeout=0.01,
        ) as client:
            with pytest.raises(AppServerError, match="timed out"):
                await client.request("never", {})

    async def response_errors() -> None:
        error_transport = ScriptedTransport(
            lambda message: [
                {
                    "id": message["id"],
                    "error": {"code": 42, "message": "rejected"},
                }
            ]
        )
        async with RpcClient(error_transport, request_timeout=0.1) as client:
            with pytest.raises(AppServerError, match=r"failed \(42\)"):
                await client.request("bad", {})
        invalid_transport = ScriptedTransport(lambda message: [{"id": message["id"], "result": []}])
        async with RpcClient(invalid_transport, request_timeout=0.1) as client:
            with pytest.raises(AppServerError, match="non-object"):
                await client.request("bad", {})

    run(timeout())
    run(response_errors())


def test_direct_unix_websocket_transport_round_trip() -> None:
    with tempfile.TemporaryDirectory(prefix="notify-wake-") as directory:
        socket_path = Path(directory) / "server.sock"

        async def scenario() -> None:
            async def handler(connection: Any) -> None:
                request = json.loads(await connection.recv())
                await connection.send(json.dumps({"id": request["id"], "result": {"ok": True}}))

            server = await unix_serve(handler, path=str(socket_path))
            async with server:
                transport = await UnixWebSocketTransport.connect(socket_path)
                await transport.send({"id": 1, "method": "ping", "params": {}})
                assert await transport.receive() == {"id": 1, "result": {"ok": True}}
                await transport.close()

        run(scenario())
        with pytest.raises(AppServerError, match="could not connect"):
            run(UnixWebSocketTransport.connect(Path(directory) / "missing.sock"))


def test_low_level_app_server_helpers_are_strict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    assert initialize_params()["capabilities"] == {"experimentalApi": True}
    assert isinstance(
        run(_connect(lambda: ScriptedTransport(app_server_handler()))),
        ScriptedTransport,
    )

    async def async_connect() -> MessageTransport:
        return ScriptedTransport(app_server_handler())

    assert isinstance(run(_connect(async_connect)), ScriptedTransport)
    with pytest.raises(AppServerError, match="invalid JSON"):
        _decode_message("{")
    with pytest.raises(AppServerError, match="JSON object"):
        _decode_message("[]")
    assert _decode_message(b'{"ok":true}') == {"ok": True}
    assert _sanitize_error_text("\n\x00") == "unspecified error"
    assert len(_sanitize_error_text("x" * 1000)) == 500
    assert _find_client_message({"turns": []}, EVENT_ID) == (None, True)
    with pytest.raises(AppServerError, match="missing turns"):
        _find_client_message({}, EVENT_ID)

    pending = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )
    with pytest.raises(StateError, match="ledger entry"):
        _accepted_from_ledger(pending, {})
    with pytest.raises(StateError, match="timestamp"):
        _accepted_from_ledger(
            pending,
            {
                "accepted_at": "bad",
                "rpc_method": "turn/steer",
                "turn_id": ACTIVE_TURN_ID,
            },
        )

    def fail_run(*_args: object, **_kwargs: object) -> object:
        raise OSError("missing codex")

    monkeypatch.setattr(subprocess, "run", fail_run)
    with pytest.raises(AppServerError, match="execute"):
        _run_daemon_version(("codex",))


def test_wake_prompt_contains_identifiers_but_not_process_arguments(
    tmp_path: Path,
) -> None:
    prompt = build_wake_prompt(
        watch_record(),
        terminal_record(),
        tmp_path / WATCH_ID,
    )
    assert WATCH_ID in prompt
    assert EVENT_ID in prompt
    assert "/tmp/evidence.json" in prompt
    assert "secret-command-argument" not in prompt


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({}, "missing the effective permission"),
        ({"activePermissionProfile": []}, "invalid effective permission"),
        (
            {"activePermissionProfile": {"id": PERMISSION_PROFILE}},
            "missing the effective approval",
        ),
        (
            {
                "activePermissionProfile": {"id": PERMISSION_PROFILE},
                "approvalPolicy": "always",
            },
            "invalid approval policy",
        ),
    ],
)
def test_effective_context_requires_complete_supported_authority(
    payload: dict[str, Any],
    message: str,
) -> None:
    with pytest.raises(AppServerError, match=message) as error:
        _effective_context_from_resume(payload)
    assert error.value.permanent


def test_thread_result_and_history_validation_helpers() -> None:
    with pytest.raises(AppServerError, match="missing thread"):
        _thread_from_result({}, "thread/read", THREAD_ID)
    with pytest.raises(AppServerError, match="unexpected thread"):
        _thread_from_result(
            {"thread": {"id": "other"}},
            "thread/read",
            THREAD_ID,
        )
    assert _find_client_message(
        {
            "turns": [
                "invalid",
                {"id": ACTIVE_TURN_ID},
                {"id": ACTIVE_TURN_ID, "items": ["invalid"]},
            ]
        },
        EVENT_ID,
    ) == (None, False)


def test_deliver_routes_in_flight_state_to_reconciliation(tmp_path: Path) -> None:
    store = prepared_store(tmp_path)
    store.write_notification(
        WATCH_ID,
        store.read_notification(WATCH_ID)
        .mark_in_flight(NOW, rpc_method="turn/steer")
        .mark_uncertain(sent_at=NOW, reason="lost"),
    )
    transport = ScriptedTransport(app_server_handler(history_client_id=EVENT_ID))
    result = run(
        deliver_notification(
            store,
            WATCH_ID,
            lambda: transport,
            now=lambda: NOW,
        )
    )
    assert result.state == "accepted"


def test_reconcile_returns_non_uncertain_state_without_transport(
    tmp_path: Path,
) -> None:
    store = prepared_store(tmp_path)
    result = run(
        reconcile_uncertain_delivery(
            store,
            WATCH_ID,
            lambda: (_ for _ in ()).throw(AssertionError("must not connect")),
            now=lambda: NOW,
        )
    )
    assert result.state == "pending"


def test_capture_from_daemon_uses_direct_socket(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    socket_path = tmp_path / "daemon.sock"
    transport = ScriptedTransport(app_server_handler())
    monkeypatch.setattr(
        "notify_wake.app_server.discover_daemon_socket",
        lambda: socket_path,
    )

    async def connect(_path: Path) -> UnixWebSocketTransport:
        return cast(UnixWebSocketTransport, transport)

    monkeypatch.setattr(UnixWebSocketTransport, "connect", connect)
    captured, selected_socket = run(
        capture_wake_context_from_daemon(
            thread_id=THREAD_ID,
            requested_permission_profile=None,
            captured_at=NOW,
        )
    )
    assert captured.permission_profile == PERMISSION_PROFILE
    assert selected_socket == socket_path


@pytest.mark.parametrize(
    ("thread_status", "turns", "expected_blocker"),
    [
        ("active", None, None),
        ("idle", [], "atomic idle-start"),
        ("active", [], "exactly one steerable turn"),
    ],
)
def test_capture_wake_readiness_reads_current_thread_state(
    thread_status: str,
    turns: list[dict[str, Any]] | None,
    expected_blocker: str | None,
) -> None:
    transport = ScriptedTransport(
        app_server_handler(thread_status=thread_status, turns=turns),
    )

    captured, blocker = run(
        capture_wake_readiness(
            thread_id=THREAD_ID,
            requested_permission_profile=None,
            transport=transport,
            captured_at=NOW,
        )
    )

    assert captured.permission_profile == PERMISSION_PROFILE
    if expected_blocker is None:
        assert blocker is None
    else:
        assert expected_blocker in (blocker or "")
    assert any(message.get("method") == "thread/read" for message in transport.sent)


def test_readiness_from_daemon_uses_direct_socket(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    socket_path = tmp_path / "daemon.sock"
    transport = ScriptedTransport(app_server_handler())
    monkeypatch.setattr(
        "notify_wake.app_server.discover_daemon_socket",
        lambda: socket_path,
    )

    async def connect(_path: Path) -> UnixWebSocketTransport:
        return cast(UnixWebSocketTransport, transport)

    monkeypatch.setattr(UnixWebSocketTransport, "connect", connect)
    captured, selected_socket, blocker = run(
        capture_wake_readiness_from_daemon(
            thread_id=THREAD_ID,
            requested_permission_profile=None,
            captured_at=NOW,
        )
    )

    assert captured.permission_profile == PERMISSION_PROFILE
    assert selected_socket == socket_path
    assert blocker is None
