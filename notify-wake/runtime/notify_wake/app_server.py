"""Direct, permission-aware delivery through the managed Codex app server."""

from __future__ import annotations

import asyncio
import inspect
import json
import re
import subprocess
from collections.abc import AsyncIterator, Awaitable, Callable, Mapping
from contextlib import asynccontextmanager, suppress
from datetime import UTC, datetime, timedelta
from pathlib import Path
from random import Random
from typing import Any, Protocol, cast

from websockets.asyncio.client import ClientConnection, unix_connect
from websockets.exceptions import WebSocketException

from .models import (
    MAX_ERROR_LENGTH,
    ModelError,
    NotificationRecord,
    TerminalRecord,
    WakeContext,
    WatchRecord,
    normalize_approval_policy,
    normalize_datetime,
)
from .state import StateError, WatchStore

APP_SERVER_MESSAGE_LIMIT_BYTES = 16 * 1024 * 1024
CLIENT_NAME = "notify_wake_local_process"
CLIENT_TITLE = "Notify-Wake Local Process Adapter"
CLIENT_VERSION = "1.0.0"
DEFAULT_REQUEST_TIMEOUT_SECONDS = 15.0
RETRY_BASE_SECONDS = 5.0
RETRY_FACTOR = 2.0
RETRY_CAP_SECONDS = 300.0
SERVER_REQUEST_REJECTION_CODE = -32601
SERVER_REQUEST_REJECTION_MESSAGE = "This client does not handle server requests"
MINIMUM_APP_SERVER_VERSION = (0, 146, 0)

JsonObject = dict[str, Any]


class MessageTransport(Protocol):
    """One JSON object per local transport message."""

    async def send(self, message: JsonObject) -> None: ...

    async def receive(self) -> JsonObject: ...

    async def close(self) -> None: ...


TransportFactory = Callable[
    [],
    MessageTransport | Awaitable[MessageTransport],
]


class AppServerError(RuntimeError):
    """A bounded app-server or delivery error."""

    def __init__(
        self,
        message: str,
        *,
        permanent: bool = False,
        request_may_have_reached: bool = False,
        explicit_rejection: bool = False,
    ) -> None:
        super().__init__(message)
        self.permanent = permanent
        self.request_may_have_reached = request_may_have_reached
        self.explicit_rejection = explicit_rejection


class UnixWebSocketTransport:
    """Headerless JSON-RPC over the managed daemon's Unix WebSocket."""

    def __init__(self, connection: ClientConnection) -> None:
        self._connection = connection

    @classmethod
    async def connect(cls, socket_path: Path) -> UnixWebSocketTransport:
        path = socket_path.expanduser().resolve(strict=False)
        try:
            connection = await unix_connect(
                path=str(path),
                uri="ws://localhost",
                compression=None,
                max_size=APP_SERVER_MESSAGE_LIMIT_BYTES,
                user_agent_header=None,
            )
        except (OSError, ValueError, WebSocketException) as error:
            raise AppServerError(
                f"could not connect to app-server Unix socket {path}: {error}"
            ) from error
        return cls(connection)

    async def send(self, message: JsonObject) -> None:
        try:
            await self._connection.send(json.dumps(message, separators=(",", ":")))
        except (ConnectionError, OSError, WebSocketException) as error:
            raise AppServerError(f"could not write to app-server socket: {error}") from error

    async def receive(self) -> JsonObject:
        try:
            message = await self._connection.recv()
        except (ConnectionError, OSError, WebSocketException) as error:
            raise AppServerError(f"app-server socket read failed: {error}") from error
        return _decode_message(message)

    async def close(self) -> None:
        await self._connection.close()


class RpcClient:
    """Concurrent response dispatcher for app-server's headerless JSON-RPC."""

    def __init__(
        self,
        transport: MessageTransport,
        *,
        request_timeout: float,
    ) -> None:
        self._transport = transport
        self._request_timeout = request_timeout
        self._next_request_id = 1
        self._pending: dict[int, asyncio.Future[JsonObject]] = {}
        self._reader: asyncio.Task[None] | None = None
        self._reader_error: AppServerError | None = None
        self._send_lock = asyncio.Lock()

    async def __aenter__(self) -> RpcClient:
        self._reader = asyncio.create_task(self._read_messages())
        return self

    async def __aexit__(
        self,
        _exception_type: type[BaseException] | None,
        _exception: BaseException | None,
        _traceback: object,
    ) -> None:
        if self._reader is not None:
            self._reader.cancel()
            with suppress(asyncio.CancelledError):
                await self._reader
        await self._transport.close()

    async def request(
        self,
        method: str,
        params: JsonObject,
        *,
        before_send: Callable[[], None] | None = None,
        wake_request: bool = False,
    ) -> JsonObject:
        if self._reader_error is not None:
            raise self._reader_error
        request_id = self._next_request_id
        self._next_request_id += 1
        future: asyncio.Future[JsonObject] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        sent_boundary_crossed = False
        try:
            if before_send is not None:
                before_send()
                sent_boundary_crossed = True
            try:
                await self._send({"id": request_id, "method": method, "params": params})
            except BaseException as error:
                if isinstance(error, (KeyboardInterrupt, SystemExit, asyncio.CancelledError)):
                    raise
                if wake_request and sent_boundary_crossed:
                    raise AppServerError(
                        f"{method} acknowledgment is uncertain: {error}",
                        request_may_have_reached=True,
                    ) from error
                if isinstance(error, AppServerError):
                    raise
                raise AppServerError(f"{method} send failed: {error}") from error
            try:
                response = await asyncio.wait_for(
                    future,
                    timeout=self._request_timeout,
                )
            except TimeoutError as error:
                raise AppServerError(
                    f"{method} timed out",
                    request_may_have_reached=wake_request and sent_boundary_crossed,
                ) from error
            except AppServerError as error:
                if wake_request and sent_boundary_crossed:
                    raise AppServerError(
                        f"{method} acknowledgment is uncertain: {error}",
                        request_may_have_reached=True,
                    ) from error
                raise
        finally:
            self._pending.pop(request_id, None)
        if "error" in response:
            rpc_error = response["error"]
            code = "unknown"
            message: object = rpc_error
            if isinstance(rpc_error, Mapping):
                code = rpc_error.get("code", "unknown")
                message = rpc_error.get("message", "unknown app-server error")
            raise AppServerError(
                f"{method} failed ({code}): {message}",
                explicit_rejection=wake_request and sent_boundary_crossed,
            )
        result = response.get("result")
        if not isinstance(result, dict):
            raise AppServerError(
                f"{method} returned a non-object result",
                request_may_have_reached=wake_request and sent_boundary_crossed,
            )
        return cast(JsonObject, result)

    async def notify(self, method: str, params: JsonObject) -> None:
        await self._send({"method": method, "params": params})

    async def _send(self, message: JsonObject) -> None:
        async with self._send_lock:
            await self._transport.send(message)

    async def _read_messages(self) -> None:
        try:
            while True:
                message = await self._transport.receive()
                message_id = message.get("id")
                method = message.get("method")
                if message_id is not None and isinstance(method, str):
                    await self._send(
                        {
                            "id": message_id,
                            "error": {
                                "code": SERVER_REQUEST_REJECTION_CODE,
                                "message": SERVER_REQUEST_REJECTION_MESSAGE,
                            },
                        }
                    )
                    continue
                if message_id is None or not isinstance(message_id, int):
                    continue
                future = self._pending.get(message_id)
                if future is not None and not future.done():
                    future.set_result(message)
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            protocol_error = (
                error
                if isinstance(error, AppServerError)
                else AppServerError(f"app-server dispatcher failed: {error}")
            )
            self._reader_error = protocol_error
            for future in self._pending.values():
                if not future.done():
                    future.set_exception(protocol_error)


def initialize_params() -> JsonObject:
    return {
        "clientInfo": {
            "name": CLIENT_NAME,
            "title": CLIENT_TITLE,
            "version": CLIENT_VERSION,
        },
        "capabilities": {"experimentalApi": True},
    }


def discover_daemon_socket(
    *,
    runner: Callable[
        [tuple[str, ...]],
        subprocess.CompletedProcess[str],
    ]
    | None = None,
) -> Path:
    """Read the managed daemon identity without starting or restarting it."""

    command = ("codex", "app-server", "daemon", "version")
    selected_runner = runner or _run_daemon_version
    result = selected_runner(command)
    if result.returncode != 0:
        detail = _sanitize_error_text(result.stderr)
        raise AppServerError(f"could not inspect managed app-server daemon: {detail}")
    try:
        payload = json.loads(result.stdout)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise AppServerError(f"managed daemon version output is invalid JSON: {error}") from error
    if not isinstance(payload, dict) or payload.get("status") != "running":
        raise AppServerError("managed app-server daemon is not running")
    socket_path = payload.get("socketPath")
    if not isinstance(socket_path, str) or not Path(socket_path).is_absolute():
        raise AppServerError("managed daemon did not report an absolute socket path")
    version = payload.get("appServerVersion")
    if not isinstance(version, str):
        raise AppServerError("managed daemon did not report appServerVersion")
    parsed_version = re.fullmatch(r"(\d+)\.(\d+)\.(\d+)(?:[-+].*)?", version)
    if parsed_version is None:
        raise AppServerError("managed daemon reported an invalid appServerVersion")
    version_tuple = tuple(int(part) for part in parsed_version.groups())
    if version_tuple < MINIMUM_APP_SERVER_VERSION:
        raise AppServerError(
            "unsupported notify-wake contract; cutover required: "
            "Codex app-server 0.146.0 or later is required",
            permanent=True,
        )
    return Path(socket_path)


async def capture_wake_context(
    *,
    thread_id: str,
    requested_permission_profile: str | None,
    transport: MessageTransport,
    captured_at: datetime | None = None,
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> WakeContext:
    """Capture effective app-server authority and goal state before dispatch."""

    context, _delivery_blocker = await _capture_wake_state(
        thread_id=thread_id,
        requested_permission_profile=requested_permission_profile,
        transport=transport,
        captured_at=captured_at,
        request_timeout=request_timeout,
        inspect_deliverability=False,
    )
    return context


async def capture_wake_readiness(
    *,
    thread_id: str,
    requested_permission_profile: str | None,
    transport: MessageTransport,
    captured_at: datetime | None = None,
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> tuple[WakeContext, str | None]:
    """Capture authority, goal state, and the current active-turn blocker."""

    return await _capture_wake_state(
        thread_id=thread_id,
        requested_permission_profile=requested_permission_profile,
        transport=transport,
        captured_at=captured_at,
        request_timeout=request_timeout,
        inspect_deliverability=True,
    )


async def _capture_wake_state(
    *,
    thread_id: str,
    requested_permission_profile: str | None,
    transport: MessageTransport,
    captured_at: datetime | None,
    request_timeout: float,
    inspect_deliverability: bool,
) -> tuple[WakeContext, str | None]:
    selected_at = normalize_datetime(
        captured_at or datetime.now(UTC),
        "captured_at",
    )
    async with RpcClient(transport, request_timeout=request_timeout) as client:
        await client.request("initialize", initialize_params())
        await client.notify("initialized", {})
        resume_params: JsonObject = {"threadId": thread_id}
        if requested_permission_profile is not None:
            resume_params["permissions"] = requested_permission_profile
        resumed = await client.request("thread/resume", resume_params)
        _thread_from_result(resumed, "thread/resume", thread_id)
        profile, approval_policy = _effective_context_from_resume(resumed)
        if requested_permission_profile is not None and profile != requested_permission_profile:
            raise AppServerError(
                "thread/resume permission profile mismatch: "
                f"expected {requested_permission_profile!r}, received {profile!r}",
                permanent=True,
            )
        goal_result = await client.request(
            "thread/goal/get",
            {"threadId": thread_id},
        )
        goal = goal_result.get("goal")
        if goal is not None and not isinstance(goal, dict):
            raise AppServerError(
                "thread/goal/get returned an invalid goal",
                permanent=True,
            )
        try:
            context = WakeContext(
                thread_id=thread_id,
                permission_profile=profile,
                approval_policy=approval_policy,
                captured_at=selected_at,
                goal_snapshot=cast(dict[str, Any] | None, goal),
            )
        except ModelError as error:
            raise AppServerError(
                f"app-server returned an invalid wake context: {error}",
                permanent=True,
            ) from error
        delivery_blocker: str | None = None
        if inspect_deliverability:
            fresh = await client.request(
                "thread/read",
                {"threadId": thread_id, "includeTurns": True},
            )
            thread = _thread_from_result(fresh, "thread/read", thread_id)
            try:
                _steerable_turn_id(thread)
            except AppServerError as error:
                delivery_blocker = str(error)
        return context, delivery_blocker


async def capture_wake_context_from_daemon(
    *,
    thread_id: str,
    requested_permission_profile: str | None,
    captured_at: datetime | None = None,
) -> tuple[WakeContext, Path]:
    socket_path = discover_daemon_socket()
    transport = await UnixWebSocketTransport.connect(socket_path)
    context = await capture_wake_context(
        thread_id=thread_id,
        requested_permission_profile=requested_permission_profile,
        transport=transport,
        captured_at=captured_at,
    )
    return context, socket_path


async def capture_wake_readiness_from_daemon(
    *,
    thread_id: str,
    requested_permission_profile: str | None,
    captured_at: datetime | None = None,
) -> tuple[WakeContext, Path, str | None]:
    socket_path = discover_daemon_socket()
    transport = await UnixWebSocketTransport.connect(socket_path)
    context, delivery_blocker = await capture_wake_readiness(
        thread_id=thread_id,
        requested_permission_profile=requested_permission_profile,
        transport=transport,
        captured_at=captured_at,
    )
    return context, socket_path, delivery_blocker


async def deliver_notification(
    store: WatchStore,
    watch_id: str,
    connect: TransportFactory,
    *,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
    random: Random | None = None,
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> NotificationRecord:
    """Attempt one serialized delivery with research compatibility by default."""

    selected_random = random or Random()
    notification = store.ensure_notification(watch_id)
    if notification.state in {"accepted", "none"}:
        return notification
    if notification.requires_history_reconciliation:
        return await reconcile_uncertain_delivery(
            store,
            watch_id,
            connect,
            now=now,
            random=selected_random,
            request_timeout=request_timeout,
        )
    if notification.state == "blocked":
        return notification
    selected_now = normalize_datetime(now(), "now")
    if (
        notification.state == "retry_due"
        and notification.next_attempt_at is not None
        and notification.next_attempt_at > selected_now
    ):
        return notification
    context = store.read_wake_context(watch_id)
    terminal = store.read_terminal(watch_id)
    watch = store.read_watch(watch_id)
    async with _async_thread_lock(store, context.thread_id) as lock_path:
        notification = store.read_notification(watch_id)
        if notification.requires_history_reconciliation:
            return notification
        if notification.state not in {"pending", "retry_due"}:
            return notification
        if (
            notification.state == "retry_due"
            and notification.next_attempt_at is not None
            and notification.next_attempt_at > selected_now
        ):
            return notification
        prior = store.read_accepted_ledger(lock_path, context.thread_id).get(terminal.event_id)
        if prior is not None:
            accepted = _accepted_from_ledger(notification, prior)
            store.write_notification(watch_id, accepted)
            store.close_watch(watch_id, now=accepted.accepted_at or selected_now)
            return accepted
        from .delivery import (
            DeliveryState as CoreDeliveryState,
        )
        from .delivery import (
            DeliveryUncertainty,
            WakeRequest,
            deliver_wake,
        )

        try:
            transport = await _connect(connect)
        except AppServerError as error:
            if error.permanent:
                blocked = notification.mark_blocked(
                    attempted_at=selected_now,
                    error=_sanitize_error_text(str(error)),
                )
                store.write_notification(watch_id, blocked)
                return blocked
            retry = _schedule_retry(
                notification,
                selected_now,
                error,
                selected_random,
                increment_attempt=True,
            )
            store.write_notification(watch_id, retry)
            return retry

        def persist_request_boundary(rpc_method: str, sent_at: datetime) -> None:
            current = store.read_notification(watch_id)
            store.write_notification(
                watch_id,
                current.mark_in_flight(sent_at, rpc_method=rpc_method),
            )

        outcome = await deliver_wake(
            WakeRequest(
                event_id=terminal.event_id,
                prompt=build_wake_prompt(watch, terminal, store.watch_dir(watch_id)),
                context=context,
            ),
            transport,
            lease=store.read_goal_wait_lease(watch_id),
            persist_lease=lambda lease: store.write_goal_wait_lease(watch_id, lease),
            persist_request_boundary=persist_request_boundary,
            now=now,
            request_timeout=request_timeout,
        )
        current = store.read_notification(watch_id)
        if outcome.state == CoreDeliveryState.UNCERTAIN:
            if outcome.uncertainty == DeliveryUncertainty.GOAL_TRANSITION:
                blocked = current.mark_blocked(
                    attempted_at=selected_now,
                    error=(
                        "goal activation acknowledgment is uncertain; "
                        "manual recovery required: "
                        f"{outcome.error or 'unknown goal transition error'}"
                    ),
                )
                store.write_notification(watch_id, blocked)
                store.append_controller_log(
                    watch_id,
                    event="goal_transition_uncertain",
                    detail=blocked.last_error,
                    occurred_at=selected_now,
                )
                return blocked
            sent_at = current.request_sent_at or outcome.request_sent_at or selected_now
            uncertain = current.mark_uncertain(
                sent_at=sent_at,
                reason=outcome.error or "wake acknowledgment is uncertain",
            )
            store.write_notification(watch_id, uncertain)
            store.append_controller_log(
                watch_id,
                event="delivery_uncertain",
                detail=uncertain.last_error,
                occurred_at=selected_now,
            )
            return uncertain
        if outcome.state == CoreDeliveryState.BLOCKED:
            blocked = current.mark_blocked(
                attempted_at=selected_now,
                error=outcome.error or "delivery is blocked",
            )
            store.write_notification(watch_id, blocked)
            store.append_controller_log(
                watch_id,
                event="delivery_blocked",
                detail=blocked.last_error,
                occurred_at=selected_now,
            )
            return blocked
        if outcome.state == CoreDeliveryState.RETRY_DUE:
            retry = _schedule_retry(
                current,
                selected_now,
                AppServerError(outcome.error or "delivery retry required"),
                selected_random,
                increment_attempt=current.state != "in_flight",
            )
            store.write_notification(watch_id, retry)
            store.append_controller_log(
                watch_id,
                event="delivery_retry_scheduled",
                detail=retry.last_error,
                occurred_at=selected_now,
            )
            return retry
        if outcome.rpc_method is None or outcome.turn_id is None:
            raise AppServerError("accepted delivery outcome lacks RPC acceptance metadata")
        accepted_at = normalize_datetime(now(), "accepted_at")
        accepted = current.mark_accepted(
            accepted_at=accepted_at,
            rpc_method=outcome.rpc_method,
            turn_id=outcome.turn_id,
        )
        ledger = store.read_accepted_ledger(lock_path, context.thread_id)
        ledger[terminal.event_id] = {
            "accepted_at": accepted_at.isoformat(),
            "rpc_method": outcome.rpc_method,
            "turn_id": outcome.turn_id,
        }
        store.write_accepted_ledger(lock_path, context.thread_id, ledger)
        store.write_notification(watch_id, accepted)
        store.close_watch(watch_id, now=accepted_at)
        store.append_controller_log(
            watch_id,
            event="delivery_accepted",
            detail=outcome.rpc_method,
            occurred_at=accepted_at,
        )
        return accepted


async def reconcile_uncertain_delivery(
    store: WatchStore,
    watch_id: str,
    connect: TransportFactory,
    *,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
    random: Random | None = None,
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> NotificationRecord:
    """Reconcile an in-flight request by exact client message identity."""

    selected_random = random or Random()
    selected_now = normalize_datetime(now(), "now")
    context = store.read_wake_context(watch_id)
    terminal = store.read_terminal(watch_id)
    watch = store.read_watch(watch_id)
    async with _async_thread_lock(store, context.thread_id) as lock_path:
        notification = store.read_notification(watch_id)
        if not notification.requires_history_reconciliation:
            return notification
        prior = store.read_accepted_ledger(lock_path, context.thread_id).get(notification.event_id)
        if prior is not None:
            accepted = _accepted_from_ledger(notification, prior)
            store.write_notification(watch_id, accepted)
            store.close_watch(watch_id, now=accepted.accepted_at or selected_now)
            return accepted
        try:
            transport = await _connect(connect)
        except AppServerError as error:
            reconciliation_error = (
                "authoritative history reconciliation unavailable: "
                f"{_sanitize_error_text(str(error))}"
            )
            if error.permanent:
                blocked = notification.mark_reconciliation_blocked(
                    attempted_at=selected_now,
                    error=reconciliation_error,
                )
                store.write_notification(watch_id, blocked)
                return blocked
            retry = _schedule_reconciliation_retry(
                notification,
                selected_now,
                reconciliation_error,
                selected_random,
            )
            store.write_notification(watch_id, retry)
            return retry
        from .delivery import (
            DeliveryState as CoreDeliveryState,
        )
        from .delivery import (
            WakeRequest,
            reconcile_wake,
        )

        rpc_method = notification.attempted_rpc_method
        if rpc_method not in {"turn/start", "turn/steer"}:
            raise AppServerError(
                "notification is missing the attempted wake RPC method",
                permanent=True,
            )
        outcome = await reconcile_wake(
            WakeRequest(
                event_id=terminal.event_id,
                prompt=build_wake_prompt(watch, terminal, store.watch_dir(watch_id)),
                context=context,
            ),
            transport,
            attempted_rpc_method=rpc_method,
            lease=store.read_goal_wait_lease(watch_id),
            persist_lease=lambda lease: store.write_goal_wait_lease(watch_id, lease),
            now=now,
            request_timeout=request_timeout,
        )
        if outcome.state == CoreDeliveryState.ACCEPTED:
            if outcome.turn_id is None:
                raise AppServerError("accepted reconciliation lacks a turn ID")
            accepted = notification.mark_accepted(
                accepted_at=selected_now,
                rpc_method=rpc_method,
                turn_id=outcome.turn_id,
            )
            ledger = store.read_accepted_ledger(lock_path, context.thread_id)
            ledger[notification.event_id] = {
                "accepted_at": selected_now.isoformat(),
                "rpc_method": rpc_method,
                "turn_id": outcome.turn_id,
            }
            store.write_accepted_ledger(lock_path, context.thread_id, ledger)
            store.write_notification(watch_id, accepted)
            store.close_watch(watch_id, now=selected_now)
            return accepted
        if outcome.state == CoreDeliveryState.BLOCKED:
            blocked = notification.mark_reconciliation_blocked(
                attempted_at=selected_now,
                error=outcome.error or "authoritative history reconciliation is blocked",
            )
            store.write_notification(watch_id, blocked)
            return blocked
        error = outcome.error or "authoritative history reconciliation failed"
        if "proves the wake is absent" in error:
            retry = _schedule_retry(
                notification,
                selected_now,
                AppServerError(error),
                selected_random,
                increment_attempt=False,
            )
        else:
            retry = _schedule_reconciliation_retry(
                notification,
                selected_now,
                error,
                selected_random,
            )
        store.write_notification(watch_id, retry)
        return retry


def build_wake_prompt(
    watch: WatchRecord,
    terminal: TerminalRecord,
    state_path: Path,
) -> str:
    """Build a fixed trusted wake input from validated identifiers only."""

    evidence = "\n".join(f"- {path}" for path in terminal.evidence_paths)
    evidence_section = evidence or "- none"
    target = terminal.target
    return (
        "A registered local process watch requires attention.\n"
        f"Watch: {watch.watch_id}\n"
        f"Event: {terminal.event_id}\n"
        f"Target PID: {target.pid}\n"
        f"Target start ticks: {target.start_ticks}\n"
        f"Status: {terminal.status}\n"
        f"Occurred at: {terminal.occurred_at.isoformat()}\n"
        f"State: {state_path}\n"
        f"Evidence:\n{evidence_section}\n\n"
        "Read and validate the durable state and evidence before continuing."
    )


def _verify_effective_context(
    resumed: JsonObject,
    expected: WakeContext,
) -> None:
    profile, approval_policy = _effective_context_from_resume(resumed)
    if profile != expected.permission_profile:
        raise AppServerError(
            "thread/resume permission profile mismatch",
            permanent=True,
        )
    if approval_policy != expected.approval_policy:
        raise AppServerError(
            "thread/resume approval policy mismatch",
            permanent=True,
        )


def _effective_context_from_resume(
    result: JsonObject,
) -> tuple[str, object]:
    if "activePermissionProfile" not in result:
        raise AppServerError(
            "thread/resume response is missing the effective permission profile",
            permanent=True,
        )
    profile = result["activePermissionProfile"]
    if profile is None:
        raise AppServerError(
            "thread/resume did not report a selectable effective permission profile",
            permanent=True,
        )
    if not isinstance(profile, dict) or not isinstance(profile.get("id"), str):
        raise AppServerError(
            "thread/resume returned an invalid effective permission profile",
            permanent=True,
        )
    if "approvalPolicy" not in result:
        raise AppServerError(
            "thread/resume response is missing the effective approval policy",
            permanent=True,
        )
    try:
        approval_policy = normalize_approval_policy(result["approvalPolicy"])
    except ModelError as error:
        raise AppServerError(
            f"thread/resume returned an invalid approval policy: {error}",
            permanent=True,
        ) from error
    return cast(str, profile["id"]), approval_policy


def _thread_from_result(
    result: JsonObject,
    method: str,
    expected_thread_id: str,
) -> JsonObject:
    thread = result.get("thread")
    if not isinstance(thread, dict):
        raise AppServerError(f"{method} response is missing thread state")
    if thread.get("id") != expected_thread_id:
        raise AppServerError(f"{method} returned an unexpected thread")
    return cast(JsonObject, thread)


def _steerable_turn_id(thread: JsonObject) -> str:
    status = thread.get("status")
    if not isinstance(status, dict) or not isinstance(status.get("type"), str):
        raise AppServerError("thread/read returned an unknown thread status")
    status_type = status["type"]
    if status_type == "idle":
        raise AppServerError(
            "originating task is idle; atomic idle-start is unavailable",
            permanent=True,
        )
    if status_type != "active":
        raise AppServerError(f"thread is not currently deliverable in state {status_type!r}")
    turns = thread.get("turns")
    if not isinstance(turns, list):
        raise AppServerError("thread/read response is missing turns")
    in_progress = [
        turn
        for turn in turns
        if isinstance(turn, dict)
        and turn.get("status") == "inProgress"
        and isinstance(turn.get("id"), str)
    ]
    if len(in_progress) != 1:
        raise AppServerError("active thread does not have exactly one steerable turn")
    return cast(str, in_progress[0]["id"])


def _find_client_message(
    thread: JsonObject,
    event_id: str,
) -> tuple[str | None, bool]:
    turns = thread.get("turns")
    if not isinstance(turns, list):
        raise AppServerError("thread history is missing turns")
    complete = True
    for turn in turns:
        if not isinstance(turn, dict) or not isinstance(turn.get("id"), str):
            complete = False
            continue
        items = turn.get("items")
        if not isinstance(items, list):
            complete = False
            continue
        for item in items:
            if not isinstance(item, dict) or not isinstance(item.get("type"), str):
                complete = False
                continue
            if item["type"] != "userMessage":
                continue
            client_id = item.get("clientId")
            if not isinstance(client_id, str) or not client_id:
                complete = False
                continue
            if client_id == event_id:
                return cast(str, turn["id"]), complete
    return None, complete


def _accepted_from_ledger(
    notification: NotificationRecord,
    value: Mapping[str, str],
) -> NotificationRecord:
    accepted_at_value = value.get("accepted_at")
    rpc_method = value.get("rpc_method")
    turn_id = value.get("turn_id")
    if (
        accepted_at_value is None
        or rpc_method not in {"turn/start", "turn/steer"}
        or turn_id is None
    ):
        raise StateError("accepted-event ledger entry is invalid")
    try:
        accepted_at = datetime.fromisoformat(accepted_at_value.replace("Z", "+00:00"))
    except ValueError as error:
        raise StateError("accepted-event ledger timestamp is invalid") from error
    return notification.mark_accepted(
        accepted_at=accepted_at,
        rpc_method=rpc_method,
        turn_id=turn_id,
    )


def _schedule_retry(
    notification: NotificationRecord,
    attempted_at: datetime,
    error: BaseException,
    random: Random,
    *,
    increment_attempt: bool,
) -> NotificationRecord:
    projected_attempts = notification.attempt_count + (1 if increment_attempt else 0)
    exponent = max(projected_attempts - 1, 0)
    delay_cap = min(
        RETRY_CAP_SECONDS,
        RETRY_BASE_SECONDS * (RETRY_FACTOR**exponent),
    )
    next_attempt_at = attempted_at + timedelta(seconds=random.uniform(0.0, delay_cap))
    return notification.schedule_retry(
        attempted_at=attempted_at,
        error=_sanitize_error_text(str(error)),
        next_attempt_at=next_attempt_at,
        increment_attempt=increment_attempt,
    )


def _schedule_reconciliation_retry(
    notification: NotificationRecord,
    attempted_at: datetime,
    error: str,
    random: Random,
) -> NotificationRecord:
    projected_attempts = notification.attempt_count + 1
    exponent = max(projected_attempts - 1, 0)
    delay_cap = min(
        RETRY_CAP_SECONDS,
        RETRY_BASE_SECONDS * (RETRY_FACTOR**exponent),
    )
    next_attempt_at = attempted_at + timedelta(seconds=random.uniform(0.0, delay_cap))
    return notification.schedule_reconciliation_retry(
        attempted_at=attempted_at,
        error=_sanitize_error_text(error),
        next_attempt_at=next_attempt_at,
    )


async def _connect(connect: TransportFactory) -> MessageTransport:
    try:
        selected = connect()
        if inspect.isawaitable(selected):
            return await cast(Awaitable[MessageTransport], selected)
        return cast(MessageTransport, selected)
    except AppServerError:
        raise
    except BaseException as error:
        if isinstance(error, (KeyboardInterrupt, SystemExit, asyncio.CancelledError)):
            raise
        raise AppServerError(f"app-server connection failed: {error}") from error


@asynccontextmanager
async def _async_thread_lock(
    store: WatchStore,
    thread_id: str,
) -> AsyncIterator[Path]:
    lock_path, descriptor = await asyncio.to_thread(
        store.acquire_thread_lock,
        thread_id,
    )
    try:
        yield lock_path
    finally:
        store.release_thread_lock(descriptor)


def _decode_message(message: str | bytes) -> JsonObject:
    try:
        decoded = json.loads(message)
    except (UnicodeError, json.JSONDecodeError) as error:
        raise AppServerError(f"app-server returned invalid JSON: {error}") from error
    if not isinstance(decoded, dict) or not all(isinstance(key, str) for key in decoded):
        raise AppServerError("app-server message must be a JSON object")
    return cast(JsonObject, decoded)


def _run_daemon_version(
    command: tuple[str, ...],
) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AppServerError(f"could not execute managed daemon inspection: {error}") from error


def _sanitize_error_text(value: str) -> str:
    normalized = " ".join(
        "".join(
            character if ord(character) >= 32 and ord(character) != 127 else " "
            for character in value
        ).split()
    )
    return (normalized or "unspecified error")[:MAX_ERROR_LENGTH]
