from __future__ import annotations

import asyncio
from collections.abc import Callable
from datetime import UTC, datetime
from typing import Any

import pytest
from notify_wake.delivery import (
    AppServerError,
    DeliveryPolicy,
    DeliveryState,
    DeliveryTarget,
    MessageTransport,
    WakeRequest,
    deliver_wake,
    enter_notify_wait,
    reconcile_wake,
)
from notify_wake.models import ModelError, NotifyWaitLease, WakeContext

NOW = datetime(2026, 7, 29, 12, 0, tzinfo=UTC)
THREAD_ID = "019fa9c6-3613-7e60-a328-bf6f5c62c7bd"
EVENT_ID = "22345678-1234-5678-9234-567812345678"
LEASE_ID = "32345678-1234-5678-9234-567812345678"
PERMISSION_PROFILE = ":danger-full-access"
ACTIVE_TURN_ID = "active-turn"


def run(coroutine: Any) -> Any:
    return asyncio.run(coroutine)


class ScriptedTransport(MessageTransport):
    def __init__(
        self,
        handler: Callable[[dict[str, Any]], list[dict[str, Any]]],
    ) -> None:
        self._handler = handler
        self._responses: asyncio.Queue[dict[str, Any]] = asyncio.Queue()
        self.sent: list[dict[str, Any]] = []

    async def send(self, message: dict[str, Any]) -> None:
        self.sent.append(message)
        for response in self._handler(message):
            self._responses.put_nowait(response)

    async def receive(self) -> dict[str, Any]:
        return await self._responses.get()

    async def close(self) -> None:
        return None


class FailAfterMethodTransport(ScriptedTransport):
    def __init__(
        self,
        selected_handler: Callable[[dict[str, Any]], list[dict[str, Any]]],
        *,
        method: str,
    ) -> None:
        super().__init__(selected_handler)
        self._method = method

    async def send(self, message: dict[str, Any]) -> None:
        await super().send(message)
        if message.get("method") == self._method:
            raise ConnectionError(f"lost {self._method} acknowledgment")


def wake_context() -> WakeContext:
    return WakeContext(
        schema_version=2,
        thread_id=THREAD_ID,
        permission_profile=PERMISSION_PROFILE,
        approval_policy="never",
        captured_at=NOW,
        goal_snapshot=None,
    )


def goal(
    *,
    status: str = "active",
    updated_at: int = 20,
) -> dict[str, Any]:
    return {
        "threadId": THREAD_ID,
        "objective": "wait for the registered research controller",
        "status": status,
        "tokenBudget": 100_000,
        "tokensUsed": 1_000,
        "timeUsedSeconds": 20,
        "createdAt": 10,
        "updatedAt": updated_at,
    }


def handler(
    *,
    thread_status: str = "idle",
    selected_goal: dict[str, Any] | None = None,
    history_client_id: str | None = None,
    complete_history: bool = True,
    reject_wake: bool = False,
    reject_goal_set: bool = False,
    change_goal_on_set: bool = False,
    change_goal_after_activation: bool = False,
    start_turn_id: object = "started-turn",
    steer_turn_id: object = ACTIVE_TURN_ID,
    permission_profile: str = PERMISSION_PROFILE,
) -> Callable[[dict[str, Any]], list[dict[str, Any]]]:
    current_goal = None if selected_goal is None else dict(selected_goal)
    activation_completed = False

    def handle(message: dict[str, Any]) -> list[dict[str, Any]]:
        nonlocal activation_completed, current_goal
        if "id" not in message:
            return []
        request_id = message["id"]
        method = message.get("method")
        if method == "initialize":
            return [{"id": request_id, "result": {"userAgent": "fake"}}]
        if method == "thread/resume":
            return [
                {
                    "id": request_id,
                    "result": {
                        "thread": {
                            "id": THREAD_ID,
                            "status": {"type": thread_status},
                            "turns": (
                                []
                                if thread_status == "idle"
                                else [
                                    {
                                        "id": ACTIVE_TURN_ID,
                                        "status": "inProgress",
                                        "items": [],
                                    }
                                ]
                            ),
                        },
                        "activePermissionProfile": {"id": permission_profile},
                        "approvalPolicy": "never",
                    },
                }
            ]
        if method == "thread/goal/get":
            if change_goal_after_activation and activation_completed and current_goal is not None:
                current_goal = {
                    **current_goal,
                    "status": "blocked",
                    "updatedAt": current_goal["updatedAt"] + 1,
                }
            return [{"id": request_id, "result": {"goal": current_goal}}]
        if method == "thread/goal/set":
            assert current_goal is not None
            if reject_goal_set:
                return [
                    {
                        "id": request_id,
                        "error": {"code": -32000, "message": "goal transition rejected"},
                    }
                ]
            current_goal = {
                **current_goal,
                "status": message["params"]["status"],
                "updatedAt": current_goal["updatedAt"] + 1,
            }
            if change_goal_on_set:
                current_goal["objective"] = "a different goal"
            if message["params"]["status"] == "active":
                activation_completed = True
            return [{"id": request_id, "result": {"goal": current_goal}}]
        if method == "thread/read":
            turns: list[dict[str, Any]]
            if history_client_id is not None:
                turns = [
                    {
                        "id": "accepted-history-turn",
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
                turns = [{"id": "incomplete-history-turn", "status": "completed"}]
            else:
                turns = (
                    []
                    if thread_status == "idle"
                    else [
                        {
                            "id": ACTIVE_TURN_ID,
                            "status": "inProgress",
                            "items": [],
                        }
                    ]
                )
            return [
                {
                    "id": request_id,
                    "result": {
                        "thread": {
                            "id": THREAD_ID,
                            "status": {"type": thread_status},
                            "turns": turns,
                        }
                    },
                }
            ]
        if method == "turn/start":
            if reject_wake:
                return [
                    {
                        "id": request_id,
                        "error": {"code": -32000, "message": "wake rejected"},
                    }
                ]
            return [{"id": request_id, "result": {"turn": {"id": start_turn_id}}}]
        if method == "turn/steer":
            return [{"id": request_id, "result": {"turnId": steer_turn_id}}]
        raise AssertionError(f"unexpected method: {method}")

    return handle


def test_research_compatibility_is_the_default_and_preserves_root_model() -> None:
    transport = ScriptedTransport(handler())
    boundaries: list[tuple[str, datetime]] = []

    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            transport,
            persist_request_boundary=lambda method, sent_at: boundaries.append((method, sent_at)),
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.ACCEPTED
    assert outcome.rpc_method == "turn/start"
    start = next(message for message in transport.sent if message.get("method") == "turn/start")
    assert "model" not in start["params"]
    assert "effort" not in start["params"]
    assert boundaries == [("turn/start", NOW)]


def test_strict_policy_blocks_idle_start() -> None:
    transport = ScriptedTransport(handler())

    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
                policy=DeliveryPolicy.STRICT,
            ),
            transport,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.BLOCKED
    assert "idle" in (outcome.error or "")
    assert not any(message.get("method") == "turn/start" for message in transport.sent)


def test_relay_target_may_select_luna_without_changing_root_defaults() -> None:
    transport = ScriptedTransport(handler())

    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Relay the validated event to the root task.",
                context=wake_context(),
                target=DeliveryTarget.RELAY,
                relay_model="gpt-5.6-luna",
                relay_effort="medium",
            ),
            transport,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.ACCEPTED
    start = next(message for message in transport.sent if message.get("method") == "turn/start")
    assert start["params"]["model"] == "gpt-5.6-luna"
    assert start["params"]["effort"] == "medium"


def test_owned_wait_lease_reactivates_only_the_exact_blocked_goal() -> None:
    leases: list[NotifyWaitLease] = []
    block_transport = ScriptedTransport(handler(selected_goal=goal()))
    owned = run(
        enter_notify_wait(
            context=wake_context(),
            loop_id="research:study-a",
            source_ids=("controller:study-a",),
            transport=block_transport,
            persist_lease=leases.append,
            verify_loop_identity=lambda loop_id, source_ids: (
                loop_id == "research:study-a" and source_ids == ("controller:study-a",)
            ),
            lease_id=LEASE_ID,
            now=lambda: NOW,
        )
    )
    assert owned.state == "owned"
    assert owned.blocked_goal_updated_at == 21

    wake_transport = ScriptedTransport(handler(selected_goal=goal(status="blocked", updated_at=21)))
    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            wake_transport,
            lease=owned,
            persist_lease=leases.append,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.ACCEPTED
    assert outcome.lease is not None
    assert outcome.lease.state == "released"
    goal_sets = [
        message["params"]["status"]
        for message in wake_transport.sent
        if message.get("method") == "thread/goal/set"
    ]
    assert goal_sets == ["active"]


def test_manual_or_changed_blocked_goal_is_not_reactivated() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    transport = ScriptedTransport(handler(selected_goal=goal(status="blocked", updated_at=22)))

    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            transport,
            lease=owned,
            persist_lease=lambda _lease: None,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.BLOCKED
    assert "owned notify-wait lease" in (outcome.error or "")
    assert not any(message.get("method") == "thread/goal/set" for message in transport.sent)


def test_explicit_wake_rejection_restores_and_renews_owned_wait() -> None:
    leases: list[NotifyWaitLease] = []
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    transport = ScriptedTransport(
        handler(
            selected_goal=goal(status="blocked", updated_at=21),
            reject_wake=True,
        )
    )

    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            transport,
            lease=owned,
            persist_lease=leases.append,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.RETRY_DUE
    assert outcome.lease is not None
    assert outcome.lease.state == "owned"
    assert outcome.lease.blocked_goal_updated_at == 23
    assert outcome.lease.activated_goal_updated_at is None
    goal_sets = [
        message["params"]["status"]
        for message in transport.sent
        if message.get("method") == "thread/goal/set"
    ]
    assert goal_sets == ["active", "blocked"]


def test_thread_read_failure_after_activation_restores_owned_wait() -> None:
    leases: list[NotifyWaitLease] = []
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    transport = FailAfterMethodTransport(
        handler(selected_goal=goal(status="blocked", updated_at=21)),
        method="thread/read",
    )

    outcome = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            transport,
            lease=owned,
            persist_lease=leases.append,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.RETRY_DUE
    assert outcome.lease is not None
    assert outcome.lease.state == "owned"
    assert outcome.lease.blocked_goal_updated_at == 23
    assert [
        message["params"]["status"]
        for message in transport.sent
        if message.get("method") == "thread/goal/set"
    ] == ["active", "blocked"]
    assert not any(
        message.get("method") in {"turn/start", "turn/steer"} for message in transport.sent
    )


def test_absent_wake_reconciliation_restores_owned_wait() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    activated = owned.with_state(
        "activated",
        updated_at=NOW,
        activated_goal_updated_at=22,
    ).with_state(
        "uncertain",
        updated_at=NOW,
        last_error="lost wake acknowledgment",
    )
    leases: list[NotifyWaitLease] = []
    transport = ScriptedTransport(handler(selected_goal=goal(status="active", updated_at=22)))

    outcome = run(
        reconcile_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            transport,
            attempted_rpc_method="turn/start",
            lease=activated,
            persist_lease=leases.append,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.RETRY_DUE
    assert outcome.lease is not None
    assert outcome.lease.state == "owned"
    assert outcome.lease.blocked_goal_updated_at == 23


def test_incomplete_history_does_not_change_uncertain_activated_goal() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    uncertain = owned.with_state(
        "activated",
        updated_at=NOW,
        activated_goal_updated_at=22,
    ).with_state(
        "uncertain",
        updated_at=NOW,
        last_error="lost wake acknowledgment",
    )
    transport = ScriptedTransport(
        handler(
            selected_goal=goal(status="active", updated_at=22),
            complete_history=False,
        )
    )

    outcome = run(
        reconcile_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="Read the registered terminal event.",
                context=wake_context(),
            ),
            transport,
            attempted_rpc_method="turn/start",
            lease=uncertain,
            persist_lease=lambda _lease: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.BLOCKED
    assert outcome.lease == uncertain
    assert not any(message.get("method") == "thread/goal/set" for message in transport.sent)


def test_version_one_context_is_rejected_without_migration() -> None:
    payload = wake_context().to_dict()
    payload["schema_version"] = 1

    with pytest.raises(ModelError, match="cutover required"):
        WakeContext.from_dict(payload)


@pytest.mark.parametrize(
    "request_factory",
    [
        lambda: WakeRequest(
            event_id=EVENT_ID,
            prompt="",
            context=wake_context(),
        ),
        lambda: WakeRequest(
            event_id=EVENT_ID,
            prompt="x" * 16_385,
            context=wake_context(),
        ),
        lambda: WakeRequest(
            event_id=EVENT_ID,
            prompt="bad\x00prompt",
            context=wake_context(),
        ),
        lambda: WakeRequest(
            event_id=EVENT_ID,
            prompt="wake",
            context=wake_context(),
            relay_model="gpt-5.6-luna",
        ),
        lambda: WakeRequest(
            event_id=EVENT_ID,
            prompt="wake",
            context=wake_context(),
            target=DeliveryTarget.RELAY,
        ),
    ],
)
def test_wake_request_rejects_unsafe_prompt_or_model_target(
    request_factory: Callable[[], WakeRequest],
) -> None:
    with pytest.raises(ModelError):
        request_factory()


def test_enter_notify_wait_requires_exact_armed_loop_and_active_goal() -> None:
    with pytest.raises(AppServerError, match="loop identity"):
        run(
            enter_notify_wait(
                context=wake_context(),
                loop_id="research:study-a",
                source_ids=("controller:study-a",),
                transport=ScriptedTransport(handler(selected_goal=goal())),
                persist_lease=lambda _lease: None,
                verify_loop_identity=lambda _loop_id, _source_ids: False,
                lease_id=LEASE_ID,
                now=lambda: NOW,
            )
        )

    with pytest.raises(AppServerError, match="active persistent goal"):
        run(
            enter_notify_wait(
                context=wake_context(),
                loop_id="research:study-a",
                source_ids=("controller:study-a",),
                transport=ScriptedTransport(handler()),
                persist_lease=lambda _lease: None,
                verify_loop_identity=lambda _loop_id, _source_ids: True,
                lease_id=LEASE_ID,
                now=lambda: NOW,
            )
        )

    with pytest.raises(AppServerError, match="active persistent goal"):
        run(
            enter_notify_wait(
                context=wake_context(),
                loop_id="research:study-a",
                source_ids=("controller:study-a",),
                transport=ScriptedTransport(handler(selected_goal=goal(status="blocked"))),
                persist_lease=lambda _lease: None,
                verify_loop_identity=lambda _loop_id, _source_ids: True,
                lease_id=LEASE_ID,
                now=lambda: NOW,
            )
        )


def test_enter_notify_wait_records_uncertain_or_mismatched_goal_transition() -> None:
    uncertain_leases: list[NotifyWaitLease] = []
    with pytest.raises(AppServerError, match="uncertain"):
        run(
            enter_notify_wait(
                context=wake_context(),
                loop_id="research:study-a",
                source_ids=("controller:study-a",),
                transport=FailAfterMethodTransport(
                    handler(selected_goal=goal()),
                    method="thread/goal/set",
                ),
                persist_lease=uncertain_leases.append,
                verify_loop_identity=lambda _loop_id, _source_ids: True,
                lease_id=LEASE_ID,
                now=lambda: NOW,
            )
        )
    assert uncertain_leases[-1].state == "uncertain"

    mismatched_leases: list[NotifyWaitLease] = []
    with pytest.raises(AppServerError, match="different goal"):
        run(
            enter_notify_wait(
                context=wake_context(),
                loop_id="research:study-a",
                source_ids=("controller:study-a",),
                transport=ScriptedTransport(handler(selected_goal=goal(), change_goal_on_set=True)),
                persist_lease=mismatched_leases.append,
                verify_loop_identity=lambda _loop_id, _source_ids: True,
                lease_id=LEASE_ID,
                now=lambda: NOW,
            )
        )
    assert mismatched_leases[-1].state == "uncertain"

    rejected_leases: list[NotifyWaitLease] = []
    with pytest.raises(AppServerError, match="goal transition rejected"):
        run(
            enter_notify_wait(
                context=wake_context(),
                loop_id="research:study-a",
                source_ids=("controller:study-a",),
                transport=ScriptedTransport(handler(selected_goal=goal(), reject_goal_set=True)),
                persist_lease=rejected_leases.append,
                verify_loop_identity=lambda _loop_id, _source_ids: True,
                lease_id=LEASE_ID,
                now=lambda: NOW,
            )
        )
    assert rejected_leases[-1].state == "blocking_in_flight"


def test_strict_delivery_and_nonactive_goal_never_change_goal_state() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    strict = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="wake",
                context=wake_context(),
                policy=DeliveryPolicy.STRICT,
            ),
            ScriptedTransport(handler(selected_goal=goal(status="blocked", updated_at=21))),
            lease=owned,
            persist_lease=lambda _lease: None,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )
    assert strict.state == DeliveryState.BLOCKED

    paused = run(
        deliver_wake(
            WakeRequest(
                event_id=EVENT_ID,
                prompt="wake",
                context=wake_context(),
            ),
            ScriptedTransport(handler(selected_goal=goal(status="paused"))),
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )
    assert paused.state == DeliveryState.BLOCKED
    assert "paused" in (paused.error or "")


def test_goal_change_after_activation_blocks_wake_and_marks_lease_uncertain() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    leases: list[NotifyWaitLease] = []
    transport = ScriptedTransport(
        handler(
            selected_goal=goal(status="blocked", updated_at=21),
            change_goal_after_activation=True,
        )
    )

    outcome = run(
        deliver_wake(
            WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context()),
            transport,
            lease=owned,
            persist_lease=leases.append,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.BLOCKED
    assert leases[-1].state == "uncertain"
    assert not any(
        message.get("method") in {"turn/start", "turn/steer"} for message in transport.sent
    )


def test_mismatched_activation_response_is_uncertain_and_blocks_delivery() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    leases: list[NotifyWaitLease] = []

    outcome = run(
        deliver_wake(
            WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context()),
            ScriptedTransport(
                handler(
                    selected_goal=goal(status="blocked", updated_at=21),
                    change_goal_on_set=True,
                )
            ),
            lease=owned,
            persist_lease=leases.append,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.BLOCKED
    assert leases[-1].state == "uncertain"
    assert "different goal" in (outcome.error or "")


def test_lost_wake_ack_keeps_activated_goal_uncertain_for_reconciliation() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    leases: list[NotifyWaitLease] = []

    outcome = run(
        deliver_wake(
            WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context()),
            FailAfterMethodTransport(
                handler(selected_goal=goal(status="blocked", updated_at=21)),
                method="turn/start",
            ),
            lease=owned,
            persist_lease=leases.append,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.UNCERTAIN
    assert outcome.lease is not None
    assert outcome.lease.state == "uncertain"


def test_reconciliation_acceptance_releases_activated_wait() -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    uncertain = owned.with_state(
        "activated",
        updated_at=NOW,
        activated_goal_updated_at=22,
    ).with_state(
        "uncertain",
        updated_at=NOW,
        last_error="lost acknowledgment",
    )
    leases: list[NotifyWaitLease] = []

    outcome = run(
        reconcile_wake(
            WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context()),
            ScriptedTransport(
                handler(
                    selected_goal=goal(status="active", updated_at=22),
                    history_client_id=EVENT_ID,
                )
            ),
            attempted_rpc_method="turn/start",
            lease=uncertain,
            persist_lease=leases.append,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.ACCEPTED
    assert outcome.turn_id == "accepted-history-turn"
    assert leases[-1].state == "released"


def test_reconciliation_rejects_bad_method_and_unowned_activation_uncertainty() -> None:
    request = WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context())
    with pytest.raises(ModelError, match="attempted_rpc_method"):
        run(
            reconcile_wake(
                request,
                ScriptedTransport(handler()),
                attempted_rpc_method="old/start",
                now=lambda: NOW,
            )
        )

    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    uncertain = owned.with_state(
        "uncertain",
        updated_at=NOW,
        last_error="activation acknowledgment was lost",
    )
    outcome = run(
        reconcile_wake(
            request,
            ScriptedTransport(handler()),
            attempted_rpc_method="turn/start",
            lease=uncertain,
            persist_lease=lambda _lease: None,
            now=lambda: NOW,
        )
    )
    assert outcome.state == DeliveryState.BLOCKED
    assert "manual recovery" in (outcome.error or "")


@pytest.mark.parametrize(
    ("transport", "expected_state"),
    [
        (
            ScriptedTransport(handler(selected_goal=goal(status="active", updated_at=23))),
            DeliveryState.BLOCKED,
        ),
        (
            FailAfterMethodTransport(
                handler(selected_goal=goal(status="active", updated_at=22)),
                method="thread/goal/set",
            ),
            DeliveryState.BLOCKED,
        ),
        (
            ScriptedTransport(
                handler(
                    selected_goal=goal(status="active", updated_at=22),
                    change_goal_on_set=True,
                )
            ),
            DeliveryState.BLOCKED,
        ),
    ],
)
def test_reconciliation_does_not_claim_unsafe_goal_restoration(
    transport: ScriptedTransport,
    expected_state: DeliveryState,
) -> None:
    owned = NotifyWaitLease.owned(
        lease_id=LEASE_ID,
        loop_id="research:study-a",
        source_ids=("controller:study-a",),
        thread_id=THREAD_ID,
        goal=goal(status="blocked", updated_at=21),
        prepared_at=NOW,
        blocked_at=NOW,
        pre_block_updated_at=20,
    )
    uncertain = owned.with_state(
        "activated",
        updated_at=NOW,
        activated_goal_updated_at=22,
    ).with_state(
        "uncertain",
        updated_at=NOW,
        last_error="lost wake acknowledgment",
    )

    outcome = run(
        reconcile_wake(
            WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context()),
            transport,
            attempted_rpc_method="turn/start",
            lease=uncertain,
            persist_lease=lambda _lease: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == expected_state
    assert outcome.lease is not None
    assert outcome.lease.state == "uncertain"


@pytest.mark.parametrize(
    "transport",
    [
        ScriptedTransport(handler(start_turn_id=None)),
        ScriptedTransport(handler(thread_status="active", steer_turn_id="other-turn")),
    ],
)
def test_malformed_wake_acceptance_is_uncertain(
    transport: ScriptedTransport,
) -> None:
    outcome = run(
        deliver_wake(
            WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context()),
            transport,
            persist_request_boundary=lambda _method, _sent_at: None,
            now=lambda: NOW,
        )
    )

    assert outcome.state == DeliveryState.UNCERTAIN


def test_reconciliation_authority_mismatch_blocks_and_transport_failure_retries() -> None:
    request = WakeRequest(event_id=EVENT_ID, prompt="wake", context=wake_context())
    mismatched = run(
        reconcile_wake(
            request,
            ScriptedTransport(handler(permission_profile="different")),
            attempted_rpc_method="turn/start",
            now=lambda: NOW,
        )
    )
    assert mismatched.state == DeliveryState.BLOCKED

    unavailable = run(
        reconcile_wake(
            request,
            FailAfterMethodTransport(handler(), method="initialize"),
            attempted_rpc_method="turn/start",
            now=lambda: NOW,
        )
    )
    assert unavailable.state == DeliveryState.RETRY_DUE
