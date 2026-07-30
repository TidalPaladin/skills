"""Automation-safe CLI and detached local-process supervisors."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import selectors
import signal
import subprocess
import sys
from collections.abc import Sequence
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from random import Random
from typing import Any, cast
from uuid import uuid4

from .app_server import (
    AppServerError,
    UnixWebSocketTransport,
    capture_wake_readiness_from_daemon,
    deliver_notification,
    discover_daemon_socket,
    reconcile_uncertain_delivery,
)
from .delivery import DeliveryPolicy, enter_notify_wait
from .models import (
    SCHEMA_VERSION,
    ModelError,
    NotificationRecord,
    TargetIdentity,
    TerminalRecord,
    WakeContext,
    WatchRecord,
    validate_absolute_path,
    validate_uuid,
)
from .processes import (
    AttachedProcess,
    OwnedProcess,
    capture_attached_process,
    monitor_attached_process,
    pidfd_supported,
    spawn_gated_child,
    terminate_owned_process,
    wait_owned_process,
)
from .state import (
    NOTIFICATION_FILENAME,
    PROCESS_LOG_FILENAME,
    TERMINAL_FILENAME,
    StateError,
    WatchStore,
)

INTERNAL_RUN_COMMAND = "_supervise-run"
INTERNAL_ATTACH_COMMAND = "_supervise-attach"
SUPERVISOR_HANDSHAKE_TIMEOUT_SECONDS = 20.0
SUPERVISOR_SHUTDOWN_GRACE_SECONDS = 5.0
SUPERVISOR_INPUT_LIMIT_BYTES = 1024 * 1024
EXIT_SUCCESS = 0
EXIT_ATTENTION = 1
EXIT_RUNTIME_ERROR = 2
STATUS_COLORS = {
    "OK": "\x1b[1;32m",
    "WARN": "\x1b[1;33m",
    "FAIL": "\x1b[1;31m",
}
ANSI_RESET = "\x1b[0m"
SUPERVISOR_TERMINATION_SIGNALS = (signal.SIGHUP, signal.SIGTERM)


class ExpectedProblem(RuntimeError):
    """The command ran correctly but strict delivery is unavailable."""


class SupervisorInterrupted(RuntimeError):
    """A supervisor received a catchable termination signal."""


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="notify-wake",
        description="Monitor one exact local process and durably notify its Codex task.",
    )
    commands = parser.add_subparsers(dest="command", required=True)

    preflight = commands.add_parser(
        "preflight",
        help="verify managed daemon and originating task context",
    )
    _add_output_arguments(preflight)

    run = commands.add_parser(
        "run",
        help="launch and supervise one owned command",
    )
    _add_output_arguments(run)
    _add_watch_arguments(run, allow_failure_only=True)
    run.add_argument(
        "operation",
        nargs=argparse.REMAINDER,
        help="command and arguments after --",
    )

    attach = commands.add_parser(
        "attach",
        help="attach a Linux pidfd watcher to one existing PID",
    )
    _add_output_arguments(attach)
    _add_watch_arguments(attach, allow_failure_only=False)
    attach.add_argument("--pid", type=int, required=True)
    attach.add_argument("--expect-start-ticks", type=int)

    status = commands.add_parser(
        "status",
        help="read one exact durable watch",
    )
    _add_output_arguments(status)
    status.add_argument("watch_id")

    reconcile = commands.add_parser(
        "reconcile",
        help="reconcile delivery for one exact terminal watch",
    )
    _add_output_arguments(reconcile)
    reconcile.add_argument("watch_id")

    wait = commands.add_parser(
        "wait",
        help="block the exact active goal for one durably armed watch",
    )
    _add_output_arguments(wait)
    wait.add_argument("watch_id")
    return parser


def main(arguments: Sequence[str] | None = None) -> int:
    selected_arguments = list(sys.argv[1:] if arguments is None else arguments)
    if selected_arguments and selected_arguments[0] == INTERNAL_RUN_COMMAND:
        return _internal_supervise_run(selected_arguments[1:])
    if selected_arguments and selected_arguments[0] == INTERNAL_ATTACH_COMMAND:
        return _internal_supervise_attach(selected_arguments[1:])
    parser = build_parser()
    parsed = parser.parse_args(selected_arguments)
    try:
        if parsed.command == "preflight":
            payload = _preflight()
            problem = not cast(bool, payload["automatic_delivery_available"])
            render_result(
                payload,
                parsed,
                status="WARN" if problem else "OK",
            )
            return EXIT_ATTENTION if problem else EXIT_SUCCESS
        if parsed.command == "run":
            payload = _run_command(parsed)
        elif parsed.command == "attach":
            payload = _attach_command(parsed)
        elif parsed.command == "status":
            payload = _status_command(parsed.watch_id)
        elif parsed.command == "reconcile":
            payload = _reconcile_command(parsed.watch_id)
        elif parsed.command == "wait":
            payload = _wait_command(parsed.watch_id)
        else:
            raise RuntimeError(f"unsupported command: {parsed.command}")
        attention = _payload_requires_attention(payload)
        render_result(
            payload,
            parsed,
            status="WARN" if attention else "OK",
        )
        return EXIT_ATTENTION if attention else EXIT_SUCCESS
    except ExpectedProblem as error:
        _render_error(str(error), parsed)
        return EXIT_ATTENTION
    except (AppServerError, ModelError, OSError, StateError, ValueError) as error:
        _render_error(str(error), parsed)
        return EXIT_RUNTIME_ERROR


def render_result(
    payload: dict[str, object],
    arguments: argparse.Namespace,
    *,
    status: str,
) -> None:
    """Render the same deterministic primary model as text or JSON."""

    if arguments.format == "json":
        json.dump(payload, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
        return
    selected_status = _styled_status(status, arguments)
    watch_id = payload.get("watch_id", "preflight")
    lifecycle = payload.get("lifecycle", "checked")
    delivery = payload.get("delivery", "none")
    if arguments.quiet:
        sys.stdout.write(f"{selected_status}  notify-wake  {watch_id}\n")
        return
    sys.stdout.write(
        f"{selected_status}  notify-wake  {watch_id}\n\n"
        "State\n"
        f"  Lifecycle:  {lifecycle}\n"
        f"  Delivery:   {delivery}\n"
    )
    blocker = payload.get("blocker")
    if blocker is not None:
        sys.stdout.write(f"  Blocker:    {blocker}\n")
    if arguments.verbose:
        for key in sorted(payload):
            if key in {"watch_id", "lifecycle", "delivery", "blocker"}:
                continue
            value = payload[key]
            sys.stdout.write(f"  {key}: {json.dumps(value, sort_keys=True)}\n")


def _add_output_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--format",
        choices=("text", "json"),
        default="text",
    )
    parser.add_argument(
        "--color",
        choices=("auto", "always", "never"),
        default="auto",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="alias for --color never",
    )
    verbosity = parser.add_mutually_exclusive_group()
    verbosity.add_argument("--quiet", action="store_true")
    verbosity.add_argument("--verbose", action="store_true")


def _add_watch_arguments(
    parser: argparse.ArgumentParser,
    *,
    allow_failure_only: bool,
) -> None:
    parser.add_argument("--watch-id")
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        required=True,
        help=(
            "owned command runtime limit"
            if allow_failure_only
            else "maximum monitoring lifetime; the target is never signaled"
        ),
    )
    parser.add_argument(
        "--evidence",
        action="append",
        default=[],
        metavar="ABSOLUTE_PATH",
    )
    if allow_failure_only:
        parser.add_argument(
            "--wake-on",
            choices=("always", "failure"),
            default="always",
        )


def _preflight() -> dict[str, object]:
    thread_id = _required_thread_id()
    requested_profile = os.environ.get("CODEX_PERMISSION_PROFILE")
    context, socket_path, delivery_blocker = asyncio.run(
        capture_wake_readiness_from_daemon(
            thread_id=thread_id,
            requested_permission_profile=requested_profile,
        )
    )
    goal_status = context.goal_snapshot.get("status") if context.goal_snapshot is not None else None
    blocker = None
    available = True
    return {
        "watch_id": None,
        "lifecycle": "checked",
        "delivery": "available" if available else "blocked",
        "attention_required": not available,
        "automatic_delivery_available": available,
        "attach_supported": pidfd_supported(),
        "blocker": blocker,
        "delivery_policy": DeliveryPolicy.RESEARCH_COMPATIBILITY.value,
        "goal_status": goal_status,
        "non_atomic_delivery": True,
        "observed_strict_blocker": delivery_blocker,
        "permission_profile": context.permission_profile,
        "socket_path": str(socket_path),
        "thread_id": context.thread_id,
    }


def _run_command(arguments: argparse.Namespace) -> dict[str, object]:
    command = list(arguments.operation)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        raise ValueError("run requires a command after --")
    context = _capture_launch_context()
    store = WatchStore.from_environment()
    store.initialize()
    watch_id = _selected_watch_id(arguments.watch_id)
    watch_path = store.root / watch_id
    process_log = watch_path / PROCESS_LOG_FILENAME
    evidence = _validated_evidence(arguments.evidence)
    evidence_with_log = (*evidence, str(process_log))
    selected_now = datetime.now(UTC)
    watch = WatchRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=watch_id,
        mode="run",
        lifecycle="prepared",
        created_at=selected_now,
        updated_at=selected_now,
        timeout_seconds=arguments.timeout_seconds,
        wake_on=arguments.wake_on,
        evidence_paths=evidence_with_log,
        process_log_path=str(process_log),
        target=None,
    )
    store.create_watch(watch, context)
    entrypoint = Path(sys.argv[0]).resolve()
    try:
        handshake = _launch_supervisor(
            [
                sys.executable,
                str(entrypoint),
                INTERNAL_RUN_COMMAND,
                "--watch-id",
                watch_id,
            ],
            input_payload=command,
        )
        if handshake.get("status") != "active":
            raise StateError(cast(str, handshake.get("error", "run supervisor failed to arm")))
    except BaseException:
        with suppress(ModelError, OSError, StateError):
            store.discard_prepared_watch(watch_id)
        raise
    return _status_command(watch_id)


def _attach_command(arguments: argparse.Namespace) -> dict[str, object]:
    context = _capture_launch_context()
    attached = capture_attached_process(
        arguments.pid,
        expected_start_ticks=arguments.expect_start_ticks,
    )
    store = WatchStore.from_environment()
    store.initialize()
    watch_id = _selected_watch_id(arguments.watch_id)
    evidence = _validated_evidence(arguments.evidence)
    selected_now = datetime.now(UTC)
    watch = WatchRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=watch_id,
        mode="attach",
        lifecycle="active",
        created_at=selected_now,
        updated_at=selected_now,
        timeout_seconds=arguments.timeout_seconds,
        wake_on="always",
        evidence_paths=evidence,
        process_log_path=None,
        target=attached.target,
    )
    watch_created = False
    try:
        store.create_watch(watch, context)
        watch_created = True
        entrypoint = Path(sys.argv[0]).resolve()
        handshake = _launch_supervisor(
            [
                sys.executable,
                str(entrypoint),
                INTERNAL_ATTACH_COMMAND,
                "--watch-id",
                watch_id,
                "--pidfd",
                str(attached.pidfd),
            ],
            pass_fds=(attached.pidfd,),
        )
        if handshake.get("status") != "active":
            raise StateError(cast(str, handshake.get("error", "attach supervisor failed to arm")))
    except BaseException as error:
        if watch_created:
            with suppress(OSError, StateError):
                _record_monitor_error(store, watch_id, attached.target, str(error))
        raise
    finally:
        os.close(attached.pidfd)
    return _status_command(watch_id)


def _status_command(watch_id: str) -> dict[str, object]:
    selected_id = validate_uuid(watch_id, "watch_id")
    store = WatchStore.from_environment()
    store.validate_root()
    notification: NotificationRecord | None = None
    terminal: TerminalRecord | None = None
    watch_path = store.watch_dir(selected_id)
    if (watch_path / TERMINAL_FILENAME).exists():
        terminal = store.read_terminal(selected_id)
        notification = store.ensure_notification(selected_id)
    elif (watch_path / NOTIFICATION_FILENAME).exists():
        raise StateError("notification state exists without terminal truth")
    watch = store.read_watch(selected_id)
    delivery = notification.state if notification is not None else "none"
    attention_required = terminal.attention_required if terminal is not None else False
    blocker = (
        notification.last_error
        if notification is not None and notification.state == "blocked"
        else None
    )
    return {
        "watch_id": selected_id,
        "lifecycle": watch.lifecycle,
        "delivery": delivery,
        "attention_required": attention_required,
        "state_path": str(watch_path),
        "blocker": blocker,
        "target": watch.target.to_dict() if watch.target is not None else None,
        "terminal_status": terminal.status if terminal is not None else None,
        "next_attempt_at": (
            notification.next_attempt_at.isoformat()
            if notification is not None and notification.next_attempt_at is not None
            else None
        ),
        "goal_wait_state": (
            lease.state if (lease := store.read_goal_wait_lease(selected_id)) is not None else None
        ),
    }


def _reconcile_command(watch_id: str) -> dict[str, object]:
    selected_id = validate_uuid(watch_id, "watch_id")
    store = WatchStore.from_environment()
    store.validate_root()
    notification = store.ensure_notification(selected_id)

    async def connect() -> UnixWebSocketTransport:
        socket_path = discover_daemon_socket()
        return await UnixWebSocketTransport.connect(socket_path)

    if notification.requires_history_reconciliation:
        asyncio.run(
            reconcile_uncertain_delivery(
                store,
                selected_id,
                connect,
            )
        )
    elif notification.state in {"pending", "retry_due"}:
        asyncio.run(
            deliver_notification(
                store,
                selected_id,
                connect,
            )
        )
    return _status_command(selected_id)


def _wait_command(watch_id: str) -> dict[str, object]:
    selected_id = validate_uuid(watch_id, "watch_id")
    store = WatchStore.from_environment()
    store.validate_root()
    watch = store.read_watch(selected_id)
    if watch.lifecycle not in {"armed", "active"}:
        raise ExpectedProblem("notify-wait requires an armed or active watch")
    if store.read_goal_wait_lease(selected_id) is not None:
        raise ExpectedProblem("watch already has a goal-wait lease")
    context = store.read_wake_context(selected_id)

    async def block_goal() -> None:
        socket_path = discover_daemon_socket()
        transport = await UnixWebSocketTransport.connect(socket_path)
        await enter_notify_wait(
            context=context,
            loop_id=f"local-process:{selected_id}",
            source_ids=(f"watch:{selected_id}",),
            transport=transport,
            persist_lease=lambda lease: store.write_goal_wait_lease(selected_id, lease),
            verify_loop_identity=lambda loop_id, source_ids: (
                loop_id == f"local-process:{selected_id}"
                and source_ids == (f"watch:{selected_id}",)
            ),
        )

    asyncio.run(block_goal())
    return _status_command(selected_id)


def _internal_supervise_run(arguments: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--watch-id", required=True)
    parser.add_argument("--handshake-fd", type=int, required=True)
    parsed = parser.parse_args(arguments)
    store = WatchStore.from_environment()
    owned: OwnedProcess | None = None
    owned_reaped = False
    owned_wait_started = False
    registered_target: TargetIdentity | None = None
    handshake_sent = False
    previous_handlers = _install_supervisor_signal_handlers()
    try:
        command = _read_supervisor_input()
        watch = store.read_watch(parsed.watch_id)
        store.append_controller_log(
            parsed.watch_id,
            event="controller_started",
        )

        def register(target: object) -> None:
            nonlocal registered_target

            if not isinstance(target, TargetIdentity):
                raise StateError("supervisor target is invalid")
            registered_target = target
            store.activate_watch(
                parsed.watch_id,
                target,
                now=datetime.now(UTC),
            )

        if watch.process_log_path is None:
            raise StateError("owned watch is missing process_log_path")
        owned = spawn_gated_child(
            command,
            log_path=Path(watch.process_log_path),
            register=register,
        )
        _write_handshake(parsed.handshake_fd, {"status": "active"})
        handshake_sent = True
        owned_wait_started = True
        outcome = wait_owned_process(
            owned,
            timeout_seconds=watch.timeout_seconds,
        )
        owned_reaped = True
        refreshed = store.read_watch(parsed.watch_id)
        terminal = TerminalRecord(
            schema_version=SCHEMA_VERSION,
            watch_id=parsed.watch_id,
            event_id=str(uuid4()),
            target=owned.target,
            status=outcome.status,
            exit_code=outcome.exit_code,
            signal_number=outcome.signal_number,
            occurred_at=datetime.now(UTC),
            attention_required=(refreshed.wake_on == "always" or outcome.status != "succeeded"),
            evidence_paths=refreshed.evidence_paths,
        )
        store.record_terminal(terminal)
        store.append_controller_log(
            parsed.watch_id,
            event="process_terminal",
            detail=outcome.status,
        )
        asyncio.run(_deliver_until_settled(store, parsed.watch_id))
        store.append_controller_log(
            parsed.watch_id,
            event="controller_stopped",
        )
        return EXIT_SUCCESS
    except BaseException as error:
        _restore_signal_handlers(previous_handlers)
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            detail = error.__class__.__name__
        else:
            detail = str(error)
        if owned is not None and not owned_reaped and not owned_wait_started:
            with suppress(OSError, StateError):
                terminate_owned_process(owned)
        failure_target = owned.target if owned is not None else registered_target
        if failure_target is not None:
            _record_monitor_error(store, parsed.watch_id, failure_target, detail)
            _deliver_recorded_terminal(store, parsed.watch_id)
        else:
            with suppress(ModelError, OSError, StateError):
                store.discard_prepared_watch(parsed.watch_id)
        if not handshake_sent:
            _write_handshake(
                parsed.handshake_fd,
                {"status": "error", "error": detail[:500]},
            )
        with suppress(OSError, StateError):
            store.append_controller_log(
                parsed.watch_id,
                event="controller_failed",
                detail=detail,
            )
        return EXIT_RUNTIME_ERROR
    finally:
        _restore_signal_handlers(previous_handlers)
        with suppress(OSError):
            os.close(parsed.handshake_fd)


def _internal_supervise_attach(arguments: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--watch-id", required=True)
    parser.add_argument("--pidfd", type=int, required=True)
    parser.add_argument("--handshake-fd", type=int, required=True)
    parsed = parser.parse_args(arguments)
    store = WatchStore.from_environment()
    handshake_sent = False
    target: TargetIdentity | None = None
    previous_handlers = _install_supervisor_signal_handlers()
    try:
        watch = store.read_watch(parsed.watch_id)
        if watch.target is None or watch.target.kind != "attached":
            raise StateError("attach watch lacks an attached target")
        target = watch.target
        attached = AttachedProcess(target=target, pidfd=parsed.pidfd)
        store.append_controller_log(
            parsed.watch_id,
            event="controller_started",
        )
        _write_handshake(parsed.handshake_fd, {"status": "active"})
        handshake_sent = True
        outcome = monitor_attached_process(
            attached,
            timeout_seconds=watch.timeout_seconds,
        )
        terminal = TerminalRecord(
            schema_version=SCHEMA_VERSION,
            watch_id=parsed.watch_id,
            event_id=str(uuid4()),
            target=target,
            status=outcome,
            exit_code=None,
            signal_number=None,
            occurred_at=datetime.now(UTC),
            attention_required=True,
            evidence_paths=watch.evidence_paths,
        )
        store.record_terminal(terminal)
        store.append_controller_log(
            parsed.watch_id,
            event="process_terminal",
            detail=outcome,
        )
        asyncio.run(_deliver_until_settled(store, parsed.watch_id))
        store.append_controller_log(
            parsed.watch_id,
            event="controller_stopped",
        )
        return EXIT_SUCCESS
    except BaseException as error:
        _restore_signal_handlers(previous_handlers)
        detail = str(error)
        if target is not None:
            with suppress(OSError, StateError):
                _record_monitor_error(
                    store,
                    parsed.watch_id,
                    target,
                    detail,
                )
            _deliver_recorded_terminal(store, parsed.watch_id)
        if not handshake_sent:
            _write_handshake(
                parsed.handshake_fd,
                {"status": "error", "error": detail[:500]},
            )
        with suppress(OSError, StateError):
            store.append_controller_log(
                parsed.watch_id,
                event="controller_failed",
                detail=detail,
            )
        return EXIT_RUNTIME_ERROR
    finally:
        _restore_signal_handlers(previous_handlers)
        with suppress(OSError):
            os.close(parsed.handshake_fd)


async def _deliver_until_settled(
    store: WatchStore,
    watch_id: str,
) -> NotificationRecord:
    async def connect() -> UnixWebSocketTransport:
        socket_path = discover_daemon_socket()
        return await UnixWebSocketTransport.connect(socket_path)

    while True:
        notification = store.ensure_notification(watch_id)
        if notification.state in {"accepted", "blocked", "none"}:
            return notification
        if notification.state == "retry_due":
            if notification.next_attempt_at is None:
                return notification
            delay = (notification.next_attempt_at - datetime.now(UTC)).total_seconds()
            if delay > 0:
                await asyncio.sleep(delay)
        if notification.state in {"in_flight", "uncertain"}:
            await reconcile_uncertain_delivery(
                store,
                watch_id,
                connect,
            )
        else:
            await deliver_notification(
                store,
                watch_id,
                connect,
                random=Random(),
            )


def _capture_launch_context() -> WakeContext:
    thread_id = _required_thread_id()
    requested_profile = os.environ.get("CODEX_PERMISSION_PROFILE")
    context, _socket_path, _delivery_blocker = asyncio.run(
        capture_wake_readiness_from_daemon(
            thread_id=thread_id,
            requested_permission_profile=requested_profile,
        )
    )
    return context


def _required_thread_id() -> str:
    value = os.environ.get("CODEX_THREAD_ID")
    if value is None:
        raise ExpectedProblem("CODEX_THREAD_ID is required")
    return value


def _selected_watch_id(value: str | None) -> str:
    return validate_uuid(value or str(uuid4()), "watch_id")


def _validated_evidence(values: Sequence[str]) -> tuple[str, ...]:
    return tuple(
        validate_absolute_path(value, f"evidence[{index}]") for index, value in enumerate(values)
    )


def _launch_supervisor(
    command: list[str],
    *,
    input_payload: list[str] | None = None,
    pass_fds: tuple[int, ...] = (),
) -> dict[str, object]:
    handshake_read, handshake_write = os.pipe()
    child_command = [
        *command,
        "--handshake-fd",
        str(handshake_write),
    ]
    inherited_fds = (*pass_fds, handshake_write)
    process: subprocess.Popen[str] | None = None
    try:
        try:
            process = subprocess.Popen(
                child_command,
                stdin=subprocess.PIPE if input_payload is not None else subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                pass_fds=inherited_fds,
                start_new_session=True,
                text=True,
            )
        finally:
            with suppress(OSError):
                os.close(handshake_write)
        if input_payload is not None:
            if process.stdin is None:
                raise StateError("supervisor stdin is unavailable")
            try:
                process.stdin.write(json.dumps(input_payload))
                process.stdin.close()
            except (OSError, ValueError) as error:
                raise StateError(f"could not send supervisor input: {error}") from error
        selector = selectors.DefaultSelector()
        try:
            selector.register(handshake_read, selectors.EVENT_READ)
            events = selector.select(SUPERVISOR_HANDSHAKE_TIMEOUT_SECONDS)
            if not events:
                raise StateError("supervisor did not confirm active state")
            payload = os.read(handshake_read, 4096)
        finally:
            selector.close()
        if not payload:
            raise StateError("supervisor closed before confirming active state")
        try:
            decoded = json.loads(payload)
        except (UnicodeError, json.JSONDecodeError) as error:
            raise StateError("supervisor returned an invalid handshake") from error
        if not isinstance(decoded, dict):
            raise StateError("supervisor handshake must be a JSON object")
        return cast(dict[str, object], decoded)
    except BaseException:
        if process is not None:
            with suppress(OSError, subprocess.SubprocessError):
                _terminate_supervisor_process(process)
        raise
    finally:
        with suppress(OSError):
            os.close(handshake_read)


def _terminate_supervisor_process(process: subprocess.Popen[str]) -> None:
    _signal_supervisor_process_group(
        process,
        signal.SIGTERM,
        fallback_to_process=True,
    )
    try:
        process.wait(timeout=SUPERVISOR_SHUTDOWN_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        _signal_supervisor_process_group(
            process,
            signal.SIGKILL,
            fallback_to_process=True,
        )
        process.wait()
    else:
        _signal_supervisor_process_group(
            process,
            signal.SIGKILL,
            fallback_to_process=False,
        )


def _signal_supervisor_process_group(
    process: subprocess.Popen[str],
    signal_number: int,
    *,
    fallback_to_process: bool,
) -> None:
    try:
        os.killpg(process.pid, signal_number)
    except ProcessLookupError:
        if fallback_to_process:
            with suppress(ProcessLookupError):
                if signal_number == signal.SIGKILL:
                    process.kill()
                else:
                    process.terminate()


def _read_supervisor_input() -> list[str]:
    payload = sys.stdin.read(SUPERVISOR_INPUT_LIMIT_BYTES + 1)
    if len(payload.encode()) > SUPERVISOR_INPUT_LIMIT_BYTES:
        raise StateError("supervisor command payload exceeds the size limit")
    try:
        command = json.loads(payload)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise StateError("supervisor command payload is invalid JSON") from error
    if (
        not isinstance(command, list)
        or not command
        or not all(isinstance(value, str) and value for value in command)
    ):
        raise StateError("supervisor command must be a non-empty string array")
    return cast(list[str], command)


def _write_handshake(descriptor: int, payload: dict[str, object]) -> None:
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    os.write(descriptor, encoded)


def _install_supervisor_signal_handlers() -> dict[int, Any]:
    previous: dict[int, Any] = {}

    def interrupt(signal_number: int, _frame: object) -> None:
        name = signal.Signals(signal_number).name
        raise SupervisorInterrupted(f"supervisor interrupted by {name}")

    for signal_number in SUPERVISOR_TERMINATION_SIGNALS:
        previous[signal_number] = signal.signal(signal_number, interrupt)
    return previous


def _restore_signal_handlers(previous: dict[int, Any]) -> None:
    for signal_number, handler in previous.items():
        signal.signal(signal_number, handler)


def _record_monitor_error(
    store: WatchStore,
    watch_id: str,
    target: object,
    detail: str,
) -> None:
    from .models import TargetIdentity

    if not isinstance(target, TargetIdentity):
        return
    watch = store.read_watch(watch_id)
    terminal = TerminalRecord(
        schema_version=SCHEMA_VERSION,
        watch_id=watch_id,
        event_id=str(uuid4()),
        target=target,
        status="monitor_error",
        exit_code=None,
        signal_number=None,
        occurred_at=datetime.now(UTC),
        attention_required=True,
        evidence_paths=watch.evidence_paths,
    )
    with suppress(OSError, StateError):
        store.record_terminal(terminal)


def _deliver_recorded_terminal(store: WatchStore, watch_id: str) -> None:
    try:
        asyncio.run(_deliver_until_settled(store, watch_id))
    except Exception as error:
        with suppress(OSError, StateError):
            store.append_controller_log(
                watch_id,
                event="terminal_delivery_failed",
                detail=str(error),
            )


def _payload_requires_attention(payload: dict[str, object]) -> bool:
    delivery = payload.get("delivery")
    return delivery in {"pending", "blocked", "uncertain", "retry_due", "in_flight"} or bool(
        payload.get("blocker")
    )


def _styled_status(status: str, arguments: argparse.Namespace) -> str:
    if arguments.format != "text" or arguments.no_color:
        return status
    if arguments.color == "never":
        return status
    if arguments.color == "auto" and not sys.stdout.isatty():
        return status
    color = STATUS_COLORS.get(status)
    return f"{color}{status}{ANSI_RESET}" if color is not None else status


def _render_error(message: str, arguments: argparse.Namespace) -> None:
    if arguments.format == "json":
        json.dump(
            {"error": message, "tool": "notify-wake"},
            sys.stdout,
            indent=2,
            sort_keys=True,
        )
        sys.stdout.write("\n")
        return
    sys.stderr.write(f"notify-wake failed: {message}\n")
