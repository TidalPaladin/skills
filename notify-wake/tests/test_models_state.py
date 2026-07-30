from __future__ import annotations

import json
import os
from dataclasses import replace
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import pytest
from notify_wake.models import (
    MAX_DELIVERY_ATTEMPTS,
    SCHEMA_VERSION,
    Lifecycle,
    ModelError,
    NotificationRecord,
    TargetIdentity,
    TargetKind,
    TerminalRecord,
    WakeContext,
    WatchRecord,
    earliest_retry_at,
    isoformat,
    normalize_approval_policy,
    parse_datetime,
    validate_absolute_path,
    validate_goal_snapshot,
    validate_text,
    validate_uuid,
)
from notify_wake.state import (
    CONTROLLER_LOG_FILENAME,
    NOTIFICATION_FILENAME,
    ROOT_MARKER,
    STATE_LOCK_FILENAME,
    StateError,
    WatchStore,
    default_state_root,
    ensure_regular_private_file,
)

NOW = datetime(2026, 7, 28, 18, 0, tzinfo=UTC)
WATCH_ID = "12345678-1234-5678-9234-567812345678"
OTHER_WATCH_ID = "22345678-1234-5678-9234-567812345678"
EVENT_ID = "32345678-1234-5678-9234-567812345678"
OTHER_EVENT_ID = "42345678-1234-5678-9234-567812345678"
THREAD_ID = "thread-1"


def target(*, kind: TargetKind = "attached") -> TargetIdentity:
    if kind == "owned":
        return TargetIdentity(
            kind="owned",
            pid=123,
            process_group_id=123,
            start_ticks=456,
            identity_method="parent-handle",
        )
    return TargetIdentity(
        kind="attached",
        pid=123,
        process_group_id=None,
        start_ticks=456,
        identity_method="linux-pidfd",
    )


def context() -> WakeContext:
    return WakeContext(
        thread_id=THREAD_ID,
        permission_profile="danger-full-access",
        approval_policy="never",
        captured_at=NOW,
        goal_snapshot=None,
    )


def watch(
    *,
    lifecycle: Lifecycle = "active",
    selected_target: TargetIdentity | None = None,
) -> WatchRecord:
    return WatchRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=WATCH_ID,
        mode="attach",
        lifecycle=lifecycle,
        created_at=NOW,
        updated_at=NOW,
        timeout_seconds=30,
        wake_on="always",
        evidence_paths=("/tmp/evidence",),
        process_log_path=None,
        target=selected_target or target(),
    )


def terminal(*, event_id: str = EVENT_ID, attention: bool = True) -> TerminalRecord:
    return TerminalRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=WATCH_ID,
        event_id=event_id,
        target=target(),
        status="exited",
        exit_code=None,
        signal_number=None,
        occurred_at=NOW,
        attention_required=attention,
        evidence_paths=("/tmp/evidence",),
    )


def initialized_store(tmp_path: Path) -> WatchStore:
    store = WatchStore(tmp_path / "home" / ".codex" / "notify-wake")
    store.initialize()
    return store


def active_store(tmp_path: Path) -> WatchStore:
    store = initialized_store(tmp_path)
    store.create_watch(watch(), context())
    return store


@pytest.mark.parametrize(
    ("call", "message"),
    [
        (lambda: validate_uuid(1, "id"), "canonical UUID"),
        (
            lambda: validate_uuid("ABCDEFAB-1234-5678-9234-567812345678", "id"),
            "canonical UUID",
        ),
        (lambda: validate_text("", "value"), "non-empty"),
        (lambda: validate_text("bad\ntext", "value"), "control"),
        (lambda: validate_absolute_path("relative", "path"), "absolute"),
        (lambda: parse_datetime(1, "at"), "ISO 8601"),
        (lambda: parse_datetime("bad", "at"), "ISO 8601"),
        (lambda: parse_datetime(None, "at"), "ISO 8601"),
        (lambda: normalize_approval_policy("always"), "unsupported"),
        (lambda: normalize_approval_policy({}), "supported"),
        (
            lambda: normalize_approval_policy({"granular": []}),
            "must be an object",
        ),
        (
            lambda: normalize_approval_policy({"granular": {"mcp_elicitations": True}}),
            "invalid fields",
        ),
        (
            lambda: normalize_approval_policy(
                {
                    "granular": {
                        "mcp_elicitations": True,
                        "rules": True,
                        "sandbox_approval": "no",
                    }
                }
            ),
            "must be booleans",
        ),
        (lambda: validate_goal_snapshot([]), "object or null"),
    ],
)
def test_model_primitives_reject_invalid_values(
    call: Any,
    message: str,
) -> None:
    with pytest.raises(ModelError, match=message):
        call()


def test_model_primitives_normalize_values() -> None:
    parsed = parse_datetime("2026-07-28T13:00:00-05:00", "at")
    assert parsed == NOW
    assert parse_datetime(None, "at", optional=True) is None
    assert isoformat(parsed) == NOW.isoformat()
    assert isoformat(None) is None
    assert validate_goal_snapshot({"status": "blocked"}) == {"status": "blocked"}
    assert normalize_approval_policy(
        {
            "granular": {
                "mcp_elicitations": True,
                "rules": False,
                "sandbox_approval": True,
            }
        }
    ) == {
        "granular": {
            "mcp_elicitations": True,
            "request_permissions": False,
            "rules": False,
            "sandbox_approval": True,
            "skill_approval": False,
        }
    }


@pytest.mark.parametrize(
    ("factory", "updates", "message"),
    [
        (context, {"thread_id": ""}, "thread_id"),
        (context, {"permission_profile": ""}, "permission_profile"),
        (context, {"captured_at": datetime(2026, 1, 1)}, "UTC offset"),
        (lambda: target(), {"kind": "other"}, "target kind"),
        (lambda: target(), {"pid": 0}, "positive integer"),
        (lambda: target(), {"start_ticks": -1}, "non-negative"),
        (lambda: target(), {"identity_method": "pid"}, "identity method"),
        (
            lambda: target(),
            {"start_ticks": None},
            "require a Linux pidfd",
        ),
        (watch, {"schema_version": 1}, "cutover required"),
        (watch, {"mode": "other"}, "watch mode"),
        (watch, {"lifecycle": "other"}, "lifecycle"),
        (watch, {"timeout_seconds": 0}, "positive"),
        (watch, {"timeout_seconds": float("nan")}, "finite"),
        (watch, {"timeout_seconds": float("inf")}, "finite"),
        (watch, {"wake_on": "sometimes"}, "wake_on"),
        (terminal, {"schema_version": 1}, "cutover required"),
        (terminal, {"status": "running"}, "terminal status"),
        (terminal, {"exit_code": -1}, "non-negative"),
        (terminal, {"attention_required": 1}, "boolean"),
    ],
)
def test_durable_models_reject_invalid_fields(
    factory: Any,
    updates: dict[str, object],
    message: str,
) -> None:
    with pytest.raises(ModelError, match=message):
        replace(factory(), **updates)


def test_model_round_trips_and_lifecycle_transitions() -> None:
    selected_context = context()
    selected_target = target()
    selected_watch = watch()
    selected_terminal = terminal()
    notification = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )

    assert WakeContext.from_dict(selected_context.to_dict()) == selected_context
    assert TargetIdentity.from_dict(selected_target.to_dict()) == selected_target
    assert WatchRecord.from_dict(selected_watch.to_dict()) == selected_watch
    assert TerminalRecord.from_dict(selected_terminal.to_dict()) == selected_terminal
    assert NotificationRecord.from_dict(notification.to_dict()) == notification
    assert selected_context.resume_params()["permissions"] == "danger-full-access"
    assert selected_watch.with_lifecycle("closed", NOW).lifecycle == "closed"

    prepared = replace(selected_watch, lifecycle="prepared", target=None)
    activated = prepared.activate(selected_target, NOW + timedelta(seconds=1))
    assert activated.lifecycle == "active"
    assert activated.target == selected_target


@pytest.mark.parametrize(
    ("factory", "payload", "message"),
    [
        (WakeContext.from_dict, [], "object"),
        (TargetIdentity.from_dict, [], "object"),
        (WatchRecord.from_dict, [], "object"),
        (TerminalRecord.from_dict, [], "object"),
        (NotificationRecord.from_dict, [], "object"),
        (WakeContext.from_dict, {}, "invalid fields"),
        (TargetIdentity.from_dict, {}, "invalid fields"),
        (WatchRecord.from_dict, {}, "invalid fields"),
        (TerminalRecord.from_dict, {}, "invalid fields"),
        (NotificationRecord.from_dict, {}, "invalid fields"),
    ],
)
def test_model_deserialization_requires_exact_objects(
    factory: Any,
    payload: object,
    message: str,
) -> None:
    with pytest.raises(ModelError, match=message):
        factory(payload)


def test_notification_state_machine_covers_all_durable_boundaries() -> None:
    pending = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )
    none = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
        attention_required=False,
    )
    in_flight = pending.mark_in_flight(NOW, rpc_method="turn/steer")
    uncertain = in_flight.mark_uncertain(sent_at=NOW, reason="lost ack")
    retry = uncertain.schedule_retry(
        attempted_at=NOW,
        error="not found",
        next_attempt_at=NOW + timedelta(seconds=5),
        increment_attempt=False,
    )
    blocked = retry.mark_blocked(attempted_at=NOW, error="unsafe")
    accepted = in_flight.mark_accepted(
        accepted_at=NOW,
        rpc_method="turn/steer",
        turn_id="turn-1",
    )

    assert none.state == "none"
    assert in_flight.attempt_count == 1
    assert uncertain.uncertainty_reason == "lost ack"
    assert retry.state == "retry_due"
    assert blocked.state == "blocked"
    assert accepted.state == "accepted"
    assert earliest_retry_at((pending, accepted)) is None


def test_uncertain_history_miss_cycles_exhaust_send_attempt_limit() -> None:
    notification = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )

    for attempt in range(1, MAX_DELIVERY_ATTEMPTS + 1):
        sent_at = NOW + timedelta(seconds=attempt)
        notification = notification.mark_in_flight(sent_at, rpc_method="turn/steer")
        notification = notification.mark_uncertain(
            sent_at=sent_at,
            reason="lost acknowledgment",
        )
        notification = notification.schedule_retry(
            attempted_at=sent_at,
            error="authoritative history proves the message is absent",
            next_attempt_at=sent_at + timedelta(seconds=5),
            increment_attempt=False,
        )
        assert notification.attempt_count == attempt

    assert notification.state == "blocked"
    assert notification.next_attempt_at is None


@pytest.mark.parametrize(
    ("updates", "message"),
    [
        ({"schema_version": 1}, "cutover required"),
        ({"state": "other"}, "delivery state"),
        ({"attempt_count": -1}, "non-negative"),
        ({"state": "accepted"}, "acceptance metadata"),
        ({"state": "in_flight"}, "request_sent_at"),
        ({"state": "uncertain"}, "attempted_rpc_method"),
        ({"state": "retry_due"}, "next_attempt_at"),
        ({"state": "blocked"}, "last_error"),
        ({"attempt_count": 1}, "delivery metadata"),
        ({"accepted_rpc_method": "turn/start"}, "acceptance metadata"),
    ],
)
def test_notification_rejects_incomplete_states(
    updates: dict[str, object],
    message: str,
) -> None:
    pending = NotificationRecord.pending(
        watch_id=WATCH_ID,
        event_id=EVENT_ID,
        thread_id=THREAD_ID,
    )
    with pytest.raises(ModelError, match=message):
        replace(pending, **updates)


def test_state_root_resolution_and_registration(tmp_path: Path) -> None:
    codex_home = tmp_path / "codex"
    assert default_state_root({"CODEX_HOME": str(codex_home)}) == (
        codex_home / "notify-wake" / "v2"
    )
    with pytest.raises(StateError, match="absolute"):
        default_state_root({"CODEX_HOME": "relative"})
    with pytest.raises(StateError, match="filesystem root"):
        default_state_root({"CODEX_HOME": "/"})
    with pytest.raises(StateError, match="absolute"):
        WatchStore(Path("relative"))

    store = initialized_store(tmp_path)
    store.initialize()
    marker = json.loads((store.root / ROOT_MARKER).read_text())
    marker["kind"] = "wrong"
    (store.root / ROOT_MARKER).write_text(json.dumps(marker))
    with pytest.raises(StateError, match="exact root"):
        store.validate_root()


def test_store_rejects_symlinked_managed_root_before_registration(tmp_path: Path) -> None:
    outside = tmp_path / "outside"
    outside.mkdir()
    managed_root = tmp_path / "codex" / "notify-wake"
    managed_root.parent.mkdir()
    managed_root.symlink_to(outside, target_is_directory=True)

    with pytest.raises(StateError, match="symlink"):
        WatchStore(managed_root).initialize()

    assert not (outside / ROOT_MARKER).exists()


def test_store_round_trip_idempotency_and_recovery(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    pending = store.record_terminal(terminal())
    assert pending.state == "pending"
    assert store.record_terminal(terminal()) == pending

    notification_path = store.watch_dir(WATCH_ID) / NOTIFICATION_FILENAME
    notification_path.unlink()
    recovered = store.ensure_notification(WATCH_ID)
    assert recovered.event_id == EVENT_ID
    assert recovered.state == "pending"
    assert store.read_wake_context(WATCH_ID) == context()

    store.write_notification(
        WATCH_ID,
        recovered.mark_blocked(attempted_at=NOW, error="unsafe"),
    )
    assert store.close_watch(WATCH_ID, now=NOW).lifecycle == "closed"


@pytest.mark.parametrize(
    ("updates", "message"),
    [
        ({"watch_id": OTHER_WATCH_ID}, "watch ID"),
        ({"event_id": OTHER_EVENT_ID}, "terminal event"),
        ({"thread_id": "other-thread"}, "task ID"),
    ],
)
def test_notification_recovery_rejects_mismatched_identity(
    tmp_path: Path,
    updates: dict[str, object],
    message: str,
) -> None:
    store = active_store(tmp_path)
    notification = store.record_terminal(terminal())
    corrupted = replace(notification, **updates)
    store._atomic_write_json(
        store.watch_dir(WATCH_ID) / NOTIFICATION_FILENAME,
        corrupted.to_dict(),
    )

    with pytest.raises(StateError, match=message):
        store.ensure_notification(WATCH_ID)


@pytest.mark.parametrize(
    ("attention_required", "expected_lifecycle", "expected_delivery"),
    [
        (True, "complete", "pending"),
        (False, "closed", "none"),
    ],
)
def test_notification_recovery_repairs_terminal_lifecycle(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    attention_required: bool,
    expected_lifecycle: str,
    expected_delivery: str,
) -> None:
    store = active_store(tmp_path)
    original_write = store._atomic_write_json

    def fail_lifecycle_write(path: Path, payload: dict[str, object]) -> None:
        if path.name == "watch.json" and (path.parent / "terminal.json").exists():
            raise OSError("simulated lifecycle write failure")
        original_write(path, payload)

    monkeypatch.setattr(store, "_atomic_write_json", fail_lifecycle_write)
    with pytest.raises(OSError, match="lifecycle write failure"):
        store.record_terminal(terminal(attention=attention_required))
    assert store.read_watch(WATCH_ID).lifecycle == "active"

    monkeypatch.setattr(store, "_atomic_write_json", original_write)
    recovered = store.ensure_notification(WATCH_ID)

    assert recovered.state == expected_delivery
    assert store.read_watch(WATCH_ID).lifecycle == expected_lifecycle


def test_store_rejects_conflicting_or_misdirected_state(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    with pytest.raises(StateError, match="already exists"):
        store.create_watch(watch(), context())
    with pytest.raises(StateError, match="TargetIdentity"):
        store.activate_watch(WATCH_ID, object(), now=NOW)
    with pytest.raises(StateError, match="target does not match"):
        store.record_terminal(replace(terminal(), target=target(kind="owned")))

    store.record_terminal(terminal())
    with pytest.raises(StateError, match="different terminal"):
        store.record_terminal(terminal(event_id=OTHER_EVENT_ID))
    wrong_watch = replace(store.read_notification(WATCH_ID), watch_id=OTHER_WATCH_ID)
    with pytest.raises(StateError, match="watch ID"):
        store.write_notification(WATCH_ID, wrong_watch)
    wrong_event = replace(store.read_notification(WATCH_ID), event_id=OTHER_EVENT_ID)
    with pytest.raises(StateError, match="event does not match"):
        store.write_notification(WATCH_ID, wrong_event)


def test_store_rejects_corruption_symlinks_and_public_files(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    watch_path = store.watch_dir(WATCH_ID)
    watch_file = watch_path / "watch.json"
    watch_file.write_text("{bad json")
    with pytest.raises(StateError, match="not valid JSON"):
        store.read_watch(WATCH_ID)

    watch_file.unlink()
    watch_file.symlink_to("/tmp")
    with pytest.raises(StateError, match="symlink"):
        store.read_watch(WATCH_ID)

    public = tmp_path / "public"
    public.write_text("x")
    public.chmod(0o644)
    with pytest.raises(StateError, match="private regular"):
        ensure_regular_private_file(public)
    public.chmod(0o600)
    ensure_regular_private_file(public)


def test_store_rejects_symlinked_state_lock(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    selected_watch = store.read_watch(WATCH_ID)
    lock_path = store.watch_dir(WATCH_ID) / STATE_LOCK_FILENAME
    lock_path.unlink()
    outside = tmp_path / "outside-state-lock"
    outside.write_text("outside")
    outside.chmod(0o644)
    lock_path.symlink_to(outside)

    with pytest.raises(StateError, match="symlink"):
        store.write_watch(selected_watch)

    assert outside.stat().st_mode & 0o777 == 0o644


def test_store_rejects_public_state_lock(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    selected_watch = store.read_watch(WATCH_ID)
    lock_path = store.watch_dir(WATCH_ID) / STATE_LOCK_FILENAME
    lock_path.chmod(0o644)

    with pytest.raises(StateError, match="private regular"):
        store.write_watch(selected_watch)


def test_store_rejects_symlinked_thread_lock(tmp_path: Path) -> None:
    store = initialized_store(tmp_path)
    lock_path, descriptor = store.acquire_thread_lock(THREAD_ID)
    store.release_thread_lock(descriptor)
    lock_path.unlink()
    outside = tmp_path / "outside-thread-lock"
    outside.write_text("outside")
    outside.chmod(0o644)
    lock_path.symlink_to(outside)

    def acquire_and_release() -> None:
        _, selected_descriptor = store.acquire_thread_lock(THREAD_ID)
        store.release_thread_lock(selected_descriptor)

    with pytest.raises(StateError, match="symlink"):
        acquire_and_release()

    assert outside.stat().st_mode & 0o777 == 0o644


def test_store_ledgers_and_controller_diagnostics_are_sanitized(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    with store.thread_lock(THREAD_ID) as lock_path:
        assert store.read_accepted_ledger(lock_path, THREAD_ID) == {}
        events = {
            EVENT_ID: {
                "accepted_at": NOW.isoformat(),
                "rpc_method": "turn/steer",
                "turn_id": "turn-1",
            }
        }
        store.write_accepted_ledger(lock_path, THREAD_ID, events)
        assert store.read_accepted_ledger(lock_path, THREAD_ID) == events

        ledger_path = lock_path.with_suffix(".accepted.json")
        ledger_path.write_text(json.dumps({"schema_version": 1}))
        with pytest.raises(StateError, match="cutover required"):
            store.read_accepted_ledger(lock_path, THREAD_ID)
        ledger_path.write_text(
            json.dumps(
                {
                    "schema_version": SCHEMA_VERSION,
                    "thread_id": THREAD_ID,
                    "events": {EVENT_ID: {"turn_id": 1}},
                }
            )
        )
        with pytest.raises(StateError, match="entries are invalid"):
            store.read_accepted_ledger(lock_path, THREAD_ID)

    store.append_controller_log(
        WATCH_ID,
        event="event\nname",
        detail="detail\x00value",
        occurred_at=NOW,
    )
    log = (store.watch_dir(WATCH_ID) / CONTROLLER_LOG_FILENAME).read_text()
    record = json.loads(log)
    assert record == {
        "detail": "detail value",
        "event": "event name",
        "occurred_at": NOW.isoformat(),
    }
    assert os.stat(store.watch_dir(WATCH_ID) / CONTROLLER_LOG_FILENAME).st_mode & 0o077 == 0


def test_store_rejects_symlinked_controller_log(tmp_path: Path) -> None:
    store = active_store(tmp_path)
    outside = tmp_path / "outside-controller.log"
    outside.write_text("outside")
    outside.chmod(0o644)
    controller_log = store.watch_dir(WATCH_ID) / CONTROLLER_LOG_FILENAME
    controller_log.symlink_to(outside)

    with pytest.raises(StateError, match="symlink"):
        store.append_controller_log(WATCH_ID, event="unsafe")

    assert outside.read_text() == "outside"
    assert outside.stat().st_mode & 0o777 == 0o644


def test_atomic_write_failure_leaves_no_temporary_state(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    store = initialized_store(tmp_path)
    destination = store.root / "state.json"

    def fail_replace(_source: object, _destination: object) -> None:
        raise OSError("replace failed")

    monkeypatch.setattr(os, "replace", fail_replace)
    with pytest.raises(OSError, match="replace failed"):
        store._atomic_write_json(destination, {"ok": True})
    assert not destination.exists()
    assert not list(store.root.glob(".state.json.*.tmp"))
