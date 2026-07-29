"""Store-neutral Codex delivery and owned goal-wait lifecycle."""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any, cast
from uuid import uuid4

from .app_server import (
    DEFAULT_REQUEST_TIMEOUT_SECONDS,
    AppServerError,
    MessageTransport,
    RpcClient,
    _find_client_message,
    _thread_from_result,
    _verify_effective_context,
    initialize_params,
)
from .models import (
    MAX_ERROR_LENGTH,
    ModelError,
    NotifyWaitLease,
    WakeContext,
    normalize_datetime,
    validate_goal,
    validate_text,
    validate_uuid,
)

JsonObject = dict[str, Any]
PersistLease = Callable[[NotifyWaitLease], None]
PersistRequestBoundary = Callable[[str, datetime], None]
VerifyLoopIdentity = Callable[[str, tuple[str, ...]], bool]


class DeliveryPolicy(StrEnum):
    """Concurrency behavior used for idle tasks and persistent goals."""

    RESEARCH_COMPATIBILITY = "research_compatibility"
    STRICT = "strict"


class DeliveryTarget(StrEnum):
    """Whether the wake enters the root conversation or a low-cost relay."""

    ROOT = "root"
    RELAY = "relay"


class DeliveryState(StrEnum):
    """Store-neutral result of one delivery or reconciliation attempt."""

    ACCEPTED = "accepted"
    RETRY_DUE = "retry_due"
    UNCERTAIN = "uncertain"
    BLOCKED = "blocked"


@dataclass(frozen=True, slots=True)
class WakeRequest:
    """Validated input for one logical wake event."""

    event_id: str
    prompt: str
    context: WakeContext
    policy: DeliveryPolicy = DeliveryPolicy.RESEARCH_COMPATIBILITY
    target: DeliveryTarget = DeliveryTarget.ROOT
    relay_model: str | None = None
    relay_effort: str | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "event_id", validate_uuid(self.event_id, "event_id"))
        if (
            not isinstance(self.prompt, str)
            or not self.prompt
            or len(self.prompt) > 16_384
            or any(ord(character) < 32 and character != "\n" for character in self.prompt)
            or "\x7f" in self.prompt
        ):
            raise ModelError(
                "prompt must be non-empty text containing only printable characters and newlines"
            )
        if self.target == DeliveryTarget.ROOT and (
            self.relay_model is not None or self.relay_effort is not None
        ):
            raise ModelError("root wake requests must not override model or effort")
        if self.target == DeliveryTarget.RELAY:
            if self.relay_model is None or self.relay_effort is None:
                raise ModelError("relay wake requests require model and effort")
            object.__setattr__(
                self,
                "relay_model",
                validate_text(self.relay_model, "relay_model"),
            )
            object.__setattr__(
                self,
                "relay_effort",
                validate_text(self.relay_effort, "relay_effort"),
            )


@dataclass(frozen=True, slots=True)
class DeliveryOutcome:
    """One bounded delivery result; provider adapters persist queue state."""

    state: DeliveryState
    rpc_method: str | None = None
    turn_id: str | None = None
    error: str | None = None
    request_sent_at: datetime | None = None
    lease: NotifyWaitLease | None = None


async def enter_notify_wait(
    *,
    context: WakeContext,
    loop_id: str,
    source_ids: tuple[str, ...],
    transport: MessageTransport,
    persist_lease: PersistLease,
    verify_loop_identity: VerifyLoopIdentity,
    lease_id: str | None = None,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> NotifyWaitLease:
    """Block one exact active goal and persist acknowledged transition ownership."""

    selected_now = normalize_datetime(now(), "now")
    selected_lease_id = validate_uuid(lease_id or str(uuid4()), "lease_id")
    if not verify_loop_identity(loop_id, source_ids):
        raise AppServerError(
            "notify-wait controller or loop identity does not match the armed source",
            permanent=True,
        )
    async with RpcClient(transport, request_timeout=request_timeout) as client:
        await _initialize(client)
        await _resume_and_verify(client, context)
        current = await _read_goal(client, context.thread_id)
        if current is None:
            raise AppServerError("notify-wait requires an active persistent goal", permanent=True)
        try:
            active_goal = validate_goal(current, expected_status="active")
        except ModelError as error:
            raise AppServerError(
                f"notify-wait requires an active persistent goal: {error}",
                permanent=True,
            ) from error
        prepared = NotifyWaitLease.prepared(
            lease_id=selected_lease_id,
            loop_id=loop_id,
            source_ids=source_ids,
            thread_id=context.thread_id,
            goal=active_goal,
            prepared_at=selected_now,
        )
        persist_lease(prepared)
        in_flight = prepared.with_state(
            "blocking_in_flight",
            updated_at=selected_now,
        )

        def persist_boundary() -> None:
            persist_lease(in_flight)

        try:
            response = await client.request(
                "thread/goal/set",
                {"threadId": context.thread_id, "status": "blocked"},
                before_send=persist_boundary,
                wake_request=True,
            )
        except AppServerError as error:
            if error.request_may_have_reached:
                uncertain = in_flight.with_state(
                    "uncertain",
                    updated_at=normalize_datetime(now(), "now"),
                    last_error=_bounded_error(error),
                )
                persist_lease(uncertain)
            raise
        blocked_goal = _goal_from_response(response, "thread/goal/set")
        blocked_updated_at = cast(int, blocked_goal["updatedAt"])
        if not prepared.matches_goal(
            blocked_goal,
            status="blocked",
            updated_at=blocked_updated_at,
        ):
            uncertain = in_flight.with_state(
                "uncertain",
                updated_at=normalize_datetime(now(), "now"),
                last_error="thread/goal/set returned a different goal",
            )
            persist_lease(uncertain)
            raise AppServerError(
                "thread/goal/set returned a different goal",
                permanent=True,
            )
        blocked_at = normalize_datetime(now(), "blocked_at")
        owned = prepared.with_state(
            "owned",
            updated_at=blocked_at,
            blocked_goal_updated_at=blocked_updated_at,
            blocked_at=blocked_at,
        )
        persist_lease(owned)
        return owned


async def deliver_wake(
    request: WakeRequest,
    transport: MessageTransport,
    *,
    persist_request_boundary: PersistRequestBoundary,
    lease: NotifyWaitLease | None = None,
    persist_lease: PersistLease | None = None,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> DeliveryOutcome:
    """Deliver one wake with research compatibility as the default policy."""

    selected_now = normalize_datetime(now(), "now")
    active_lease: NotifyWaitLease | None = lease
    try:
        async with RpcClient(transport, request_timeout=request_timeout) as client:
            await _initialize(client)
            await _resume_and_verify(client, request.context)
            goal = await _read_goal(client, request.context.thread_id)
            if goal is not None:
                status = goal.get("status")
                if status == "blocked":
                    if request.policy == DeliveryPolicy.STRICT:
                        return _blocked("strict delivery does not reactivate blocked goals", lease)
                    if (
                        lease is None
                        or persist_lease is None
                        or lease.state != "owned"
                        or lease.blocked_goal_updated_at is None
                        or not lease.matches_goal(
                            goal,
                            status="blocked",
                            updated_at=lease.blocked_goal_updated_at,
                        )
                    ):
                        return _blocked(
                            "blocked goal does not match an owned notify-wait lease",
                            lease,
                        )
                    active_lease = await _activate_owned_goal(
                        client,
                        request.context,
                        lease,
                        persist_lease,
                        now,
                    )
                    activated_goal = await _read_goal(client, request.context.thread_id)
                    if (
                        active_lease.activated_goal_updated_at is None
                        or not active_lease.matches_goal(
                            activated_goal,
                            status="active",
                            updated_at=active_lease.activated_goal_updated_at,
                        )
                    ):
                        active_lease = active_lease.with_state(
                            "uncertain",
                            updated_at=normalize_datetime(now(), "now"),
                            last_error="activated goal changed before wake delivery",
                        )
                        persist_lease(active_lease)
                        return _blocked(
                            "activated goal changed before wake delivery",
                            active_lease,
                        )
                elif status != "active":
                    return _blocked(
                        f"goal state {status!r} must not be changed by notify-wake",
                        lease,
                    )
            thread_result = await client.request(
                "thread/read",
                {"threadId": request.context.thread_id, "includeTurns": True},
            )
            thread = _thread_from_result(
                thread_result,
                "thread/read",
                request.context.thread_id,
            )
            method, params = _wake_rpc(request, thread)

            def persist_boundary() -> None:
                persist_request_boundary(method, selected_now)

            try:
                response = await client.request(
                    method,
                    params,
                    before_send=persist_boundary,
                    wake_request=True,
                )
                turn_id = _accepted_turn_id(method, response, params)
            except AppServerError as error:
                if (
                    active_lease is not None
                    and active_lease.state == "activated"
                    and persist_lease is not None
                ):
                    if error.request_may_have_reached:
                        active_lease = active_lease.with_state(
                            "uncertain",
                            updated_at=normalize_datetime(now(), "now"),
                            last_error=_bounded_error(error),
                        )
                        persist_lease(active_lease)
                    else:
                        active_lease = await _restore_owned_goal(
                            client,
                            request.context,
                            active_lease,
                            persist_lease,
                            now,
                        )
                return _error_outcome(error, selected_now, active_lease)
            if (
                active_lease is not None
                and active_lease.state == "activated"
                and persist_lease is not None
            ):
                active_lease = active_lease.with_state(
                    "released",
                    updated_at=normalize_datetime(now(), "now"),
                )
                persist_lease(active_lease)
            return DeliveryOutcome(
                state=DeliveryState.ACCEPTED,
                rpc_method=method,
                turn_id=turn_id,
                request_sent_at=selected_now,
                lease=active_lease,
            )
    except AppServerError as error:
        return _error_outcome(error, selected_now, active_lease)


async def reconcile_wake(
    request: WakeRequest,
    transport: MessageTransport,
    *,
    attempted_rpc_method: str,
    lease: NotifyWaitLease | None = None,
    persist_lease: PersistLease | None = None,
    now: Callable[[], datetime] = lambda: datetime.now(UTC),
    request_timeout: float = DEFAULT_REQUEST_TIMEOUT_SECONDS,
) -> DeliveryOutcome:
    """Resolve one uncertain wake against complete authoritative task history."""

    if attempted_rpc_method not in {"turn/start", "turn/steer"}:
        raise ModelError("attempted_rpc_method must be turn/start or turn/steer")
    selected_now = normalize_datetime(now(), "now")
    active_lease = lease
    try:
        async with RpcClient(transport, request_timeout=request_timeout) as client:
            await _initialize(client)
            await _resume_and_verify(client, request.context)
            history = await client.request(
                "thread/read",
                {"threadId": request.context.thread_id, "includeTurns": True},
            )
            thread = _thread_from_result(
                history,
                "thread/read",
                request.context.thread_id,
            )
            match, complete = _find_client_message(thread, request.event_id)
            if match is not None:
                if (
                    active_lease is not None
                    and active_lease.activated_goal_updated_at is not None
                    and active_lease.state in {"activated", "uncertain"}
                    and persist_lease is not None
                ):
                    active_lease = active_lease.with_state(
                        "released",
                        updated_at=selected_now,
                    )
                    persist_lease(active_lease)
                return DeliveryOutcome(
                    state=DeliveryState.ACCEPTED,
                    rpc_method=attempted_rpc_method,
                    turn_id=match,
                    lease=active_lease,
                )
            if not complete:
                return _blocked(
                    "authoritative thread history is incomplete",
                    active_lease,
                )
            if (
                active_lease is not None
                and active_lease.state in {"activated", "uncertain"}
                and persist_lease is not None
            ):
                if active_lease.activated_goal_updated_at is None:
                    return _blocked(
                        "uncertain goal transition requires manual recovery",
                        active_lease,
                    )
                active_lease = await _restore_owned_goal(
                    client,
                    request.context,
                    active_lease,
                    persist_lease,
                    now,
                )
                if active_lease.state != "owned":
                    return _blocked(
                        "owned notify-wait could not be restored safely",
                        active_lease,
                    )
            return DeliveryOutcome(
                state=DeliveryState.RETRY_DUE,
                rpc_method=attempted_rpc_method,
                error="authoritative thread history proves the wake is absent",
                lease=active_lease,
            )
    except AppServerError as error:
        if error.permanent:
            return _blocked(_bounded_error(error), active_lease)
        return DeliveryOutcome(
            state=DeliveryState.RETRY_DUE,
            error=f"authoritative history reconciliation unavailable: {_bounded_error(error)}",
            lease=active_lease,
        )


async def _initialize(client: RpcClient) -> None:
    await client.request("initialize", initialize_params())
    await client.notify("initialized", {})


async def _resume_and_verify(client: RpcClient, context: WakeContext) -> None:
    resumed = await client.request(
        "thread/resume",
        cast(JsonObject, context.resume_params()),
    )
    _thread_from_result(resumed, "thread/resume", context.thread_id)
    _verify_effective_context(resumed, context)


async def _read_goal(client: RpcClient, thread_id: str) -> JsonObject | None:
    result = await client.request("thread/goal/get", {"threadId": thread_id})
    value = result.get("goal")
    if value is None:
        return None
    try:
        return cast(JsonObject, validate_goal(value))
    except ModelError as error:
        raise AppServerError(
            f"thread/goal/get returned an invalid goal: {error}",
            permanent=True,
        ) from error


def _goal_from_response(result: Mapping[str, Any], method: str) -> JsonObject:
    try:
        return cast(JsonObject, validate_goal(result.get("goal")))
    except ModelError as error:
        raise AppServerError(f"{method} returned an invalid goal: {error}") from error


async def _activate_owned_goal(
    client: RpcClient,
    context: WakeContext,
    lease: NotifyWaitLease,
    persist_lease: PersistLease,
    now: Callable[[], datetime],
) -> NotifyWaitLease:
    in_flight = lease.with_state(
        "activation_in_flight",
        updated_at=normalize_datetime(now(), "now"),
    )

    def persist_boundary() -> None:
        persist_lease(in_flight)

    try:
        response = await client.request(
            "thread/goal/set",
            {"threadId": context.thread_id, "status": "active"},
            before_send=persist_boundary,
            wake_request=True,
        )
    except AppServerError as error:
        if error.request_may_have_reached:
            uncertain = in_flight.with_state(
                "uncertain",
                updated_at=normalize_datetime(now(), "now"),
                last_error=_bounded_error(error),
            )
            persist_lease(uncertain)
        raise
    active_goal = _goal_from_response(response, "thread/goal/set")
    active_updated_at = cast(int, active_goal["updatedAt"])
    if not lease.matches_goal(active_goal, status="active", updated_at=active_updated_at):
        uncertain = in_flight.with_state(
            "uncertain",
            updated_at=normalize_datetime(now(), "now"),
            last_error="goal activation returned a different goal",
        )
        persist_lease(uncertain)
        raise AppServerError("goal activation returned a different goal", permanent=True)
    activated = lease.with_state(
        "activated",
        updated_at=normalize_datetime(now(), "now"),
        activated_goal_updated_at=active_updated_at,
    )
    persist_lease(activated)
    return activated


async def _restore_owned_goal(
    client: RpcClient,
    context: WakeContext,
    lease: NotifyWaitLease,
    persist_lease: PersistLease,
    now: Callable[[], datetime],
) -> NotifyWaitLease:
    if lease.activated_goal_updated_at is None:
        return lease
    current = await _read_goal(client, context.thread_id)
    if not lease.matches_goal(
        current,
        status="active",
        updated_at=lease.activated_goal_updated_at,
    ):
        uncertain = lease.with_state(
            "uncertain",
            updated_at=normalize_datetime(now(), "now"),
            last_error="activated goal changed before notify-wait restoration",
        )
        persist_lease(uncertain)
        return uncertain
    try:
        response = await client.request(
            "thread/goal/set",
            {"threadId": context.thread_id, "status": "blocked"},
            before_send=lambda: persist_lease(lease),
            wake_request=True,
        )
    except AppServerError as error:
        if error.request_may_have_reached:
            uncertain = lease.with_state(
                "uncertain",
                updated_at=normalize_datetime(now(), "now"),
                last_error=_bounded_error(error),
            )
            persist_lease(uncertain)
            return uncertain
        raise
    blocked = _goal_from_response(response, "thread/goal/set")
    blocked_updated_at = cast(int, blocked["updatedAt"])
    if not lease.matches_goal(blocked, status="blocked", updated_at=blocked_updated_at):
        uncertain = lease.with_state(
            "uncertain",
            updated_at=normalize_datetime(now(), "now"),
            last_error="goal restoration returned a different goal",
        )
        persist_lease(uncertain)
        return uncertain
    restored = lease.renew(
        updated_at=normalize_datetime(now(), "now"),
        blocked_goal_updated_at=blocked_updated_at,
    )
    persist_lease(restored)
    return restored


def _wake_rpc(request: WakeRequest, thread: JsonObject) -> tuple[str, JsonObject]:
    status = thread.get("status")
    if not isinstance(status, Mapping) or not isinstance(status.get("type"), str):
        raise AppServerError("thread/read returned an unknown thread status")
    status_type = status["type"]
    input_items = [{"type": "text", "text": request.prompt}]
    if status_type == "idle":
        if request.policy == DeliveryPolicy.STRICT:
            raise AppServerError(
                "strict delivery blocks non-atomic idle turn/start",
                permanent=True,
            )
        params: JsonObject = {
            "threadId": request.context.thread_id,
            "input": input_items,
            "clientUserMessageId": request.event_id,
        }
        if request.target == DeliveryTarget.RELAY:
            params["model"] = request.relay_model
            params["effort"] = request.relay_effort
        return "turn/start", params
    if status_type != "active":
        raise AppServerError(f"thread is not deliverable in state {status_type!r}")
    turns = thread.get("turns")
    if not isinstance(turns, list):
        raise AppServerError("thread/read response is missing turns")
    active_turns = [
        turn
        for turn in turns
        if isinstance(turn, Mapping)
        and turn.get("status") == "inProgress"
        and isinstance(turn.get("id"), str)
    ]
    if len(active_turns) != 1:
        raise AppServerError("active thread does not have exactly one steerable turn")
    turn_id = cast(str, active_turns[0]["id"])
    return (
        "turn/steer",
        {
            "threadId": request.context.thread_id,
            "input": input_items,
            "expectedTurnId": turn_id,
            "clientUserMessageId": request.event_id,
        },
    )


def _accepted_turn_id(method: str, result: JsonObject, params: JsonObject) -> str:
    if method == "turn/start":
        turn = result.get("turn")
        if not isinstance(turn, Mapping) or not isinstance(turn.get("id"), str):
            raise AppServerError(
                "turn/start response is missing the accepted turn ID",
                request_may_have_reached=True,
            )
        return cast(str, turn["id"])
    turn_id = result.get("turnId")
    expected = params.get("expectedTurnId")
    if not isinstance(turn_id, str) or turn_id != expected:
        raise AppServerError(
            "turn/steer returned an unexpected turn ID",
            request_may_have_reached=True,
        )
    return turn_id


def _bounded_error(error: BaseException) -> str:
    text = " ".join(str(error).split())
    return (text or error.__class__.__name__)[:MAX_ERROR_LENGTH]


def _blocked(error: str, lease: NotifyWaitLease | None) -> DeliveryOutcome:
    return DeliveryOutcome(
        state=DeliveryState.BLOCKED,
        error=error,
        lease=lease,
    )


def _error_outcome(
    error: AppServerError,
    sent_at: datetime,
    lease: NotifyWaitLease | None,
) -> DeliveryOutcome:
    if error.request_may_have_reached:
        state = DeliveryState.UNCERTAIN
    elif error.permanent:
        state = DeliveryState.BLOCKED
    else:
        state = DeliveryState.RETRY_DUE
    return DeliveryOutcome(
        state=state,
        error=_bounded_error(error),
        request_sent_at=sent_at if error.request_may_have_reached else None,
        lease=lease,
    )
