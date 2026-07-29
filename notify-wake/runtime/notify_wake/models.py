"""Validated durable state models for local process watches."""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from hashlib import sha256
from math import isfinite
from pathlib import Path
from typing import Any, Literal, cast
from uuid import UUID

SCHEMA_VERSION = 2
MAX_ERROR_LENGTH = 500
MAX_DELIVERY_ATTEMPTS = 8
STANDARD_APPROVAL_POLICIES = frozenset({"untrusted", "on-request", "never"})
REQUIRED_GRANULAR_FIELDS = frozenset({"mcp_elicitations", "rules", "sandbox_approval"})
OPTIONAL_GRANULAR_FIELDS = frozenset({"request_permissions", "skill_approval"})
CONTROL_CHARACTERS = re.compile(r"[\x00-\x1f\x7f]")

WatchMode = Literal["run", "attach"]
Lifecycle = Literal["prepared", "armed", "active", "complete", "closed"]
WakeOn = Literal["always", "failure"]
TargetKind = Literal["owned", "attached"]
IdentityMethod = Literal["parent-handle", "linux-pidfd"]
TerminalStatus = Literal[
    "succeeded",
    "failed",
    "signaled",
    "exited",
    "timed_out",
    "identity_lost",
    "monitor_error",
    "cancelled",
]
DeliveryState = Literal[
    "none",
    "pending",
    "in_flight",
    "uncertain",
    "retry_due",
    "accepted",
    "blocked",
]
GoalWaitState = Literal[
    "prepared",
    "blocking_in_flight",
    "owned",
    "activation_in_flight",
    "activated",
    "released",
    "restored",
    "uncertain",
]
ApprovalPolicy = str | dict[str, dict[str, bool]]

WATCH_FIELDS = frozenset(
    {
        "schema_version",
        "watch_id",
        "mode",
        "lifecycle",
        "created_at",
        "updated_at",
        "timeout_seconds",
        "wake_on",
        "evidence_paths",
        "process_log_path",
        "target",
    }
)
WAKE_CONTEXT_FIELDS = frozenset(
    {
        "schema_version",
        "thread_id",
        "permission_profile",
        "approval_policy",
        "captured_at",
        "goal_snapshot",
    }
)
GOAL_WAIT_LEASE_FIELDS = frozenset(
    {
        "schema_version",
        "lease_id",
        "loop_id",
        "source_ids",
        "thread_id",
        "goal_created_at",
        "goal_objective_sha256",
        "goal_token_budget",
        "pre_block_updated_at",
        "blocked_goal_updated_at",
        "activated_goal_updated_at",
        "state",
        "prepared_at",
        "blocked_at",
        "updated_at",
        "last_error",
    }
)
TARGET_FIELDS = frozenset(
    {
        "kind",
        "pid",
        "process_group_id",
        "start_ticks",
        "identity_method",
    }
)
TERMINAL_FIELDS = frozenset(
    {
        "schema_version",
        "watch_id",
        "event_id",
        "target",
        "status",
        "exit_code",
        "signal_number",
        "occurred_at",
        "attention_required",
        "evidence_paths",
    }
)
NOTIFICATION_FIELDS = frozenset(
    {
        "schema_version",
        "watch_id",
        "event_id",
        "thread_id",
        "state",
        "attempt_count",
        "attempted_rpc_method",
        "request_sent_at",
        "uncertainty_reason",
        "last_attempt_at",
        "next_attempt_at",
        "last_error",
        "accepted_at",
        "accepted_rpc_method",
        "accepted_turn_id",
    }
)


class ModelError(ValueError):
    """Persisted state does not satisfy the notify-wake schema."""


def validate_uuid(value: object, field_name: str) -> str:
    if not isinstance(value, str):
        raise ModelError(f"{field_name} must be a canonical UUID")
    try:
        parsed = UUID(value)
    except ValueError as error:
        raise ModelError(f"{field_name} must be a canonical UUID") from error
    if str(parsed) != value:
        raise ModelError(f"{field_name} must be a canonical UUID")
    return value


def validate_text(value: object, field_name: str, *, maximum: int = 512) -> str:
    if not isinstance(value, str) or not value or len(value) > maximum:
        raise ModelError(f"{field_name} must be a non-empty string")
    if CONTROL_CHARACTERS.search(value):
        raise ModelError(f"{field_name} must not contain control characters")
    return value


def validate_absolute_path(value: object, field_name: str) -> str:
    text = validate_text(value, field_name, maximum=4096)
    path = Path(text)
    if not path.is_absolute():
        raise ModelError(f"{field_name} must be an absolute path")
    return str(path)


def normalize_datetime(value: datetime, field_name: str) -> datetime:
    if not isinstance(value, datetime) or value.tzinfo is None or value.utcoffset() is None:
        raise ModelError(f"{field_name} must include a UTC offset")
    return value.astimezone(UTC)


def parse_datetime(
    value: object,
    field_name: str,
    *,
    optional: bool = False,
) -> datetime | None:
    if value is None and optional:
        return None
    if not isinstance(value, str):
        raise ModelError(f"{field_name} must be an ISO 8601 string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ModelError(f"{field_name} must be an ISO 8601 string") from error
    return normalize_datetime(parsed, field_name)


def isoformat(value: datetime | None) -> str | None:
    return value.isoformat() if value is not None else None


def require_exact_fields(
    payload: Mapping[str, object],
    expected: frozenset[str],
    source: str,
) -> None:
    if frozenset(payload) != expected:
        raise ModelError(f"{source} has invalid fields")


def normalize_approval_policy(value: object) -> ApprovalPolicy:
    if isinstance(value, str):
        if value not in STANDARD_APPROVAL_POLICIES:
            raise ModelError(f"unsupported approval policy: {value!r}")
        return value
    if not isinstance(value, Mapping) or frozenset(value) != {"granular"}:
        raise ModelError("approval_policy must be a supported app-server policy")
    granular = value["granular"]
    if not isinstance(granular, Mapping):
        raise ModelError("approval_policy.granular must be an object")
    fields = frozenset(granular)
    allowed = REQUIRED_GRANULAR_FIELDS | OPTIONAL_GRANULAR_FIELDS
    if not fields >= REQUIRED_GRANULAR_FIELDS or not fields <= allowed:
        raise ModelError("approval_policy.granular has invalid fields")
    if not all(isinstance(granular[field], bool) for field in fields):
        raise ModelError("approval_policy.granular fields must be booleans")
    return {
        "granular": {
            "mcp_elicitations": cast(bool, granular["mcp_elicitations"]),
            "request_permissions": cast(bool, granular.get("request_permissions", False)),
            "rules": cast(bool, granular["rules"]),
            "sandbox_approval": cast(bool, granular["sandbox_approval"]),
            "skill_approval": cast(bool, granular.get("skill_approval", False)),
        }
    }


def validate_goal_snapshot(value: object) -> dict[str, Any] | None:
    if value is None:
        return None
    if not isinstance(value, Mapping) or not all(isinstance(key, str) for key in value):
        raise ModelError("goal_snapshot must be an object or null")
    return dict(value)


def _unsupported_schema(kind: str, value: object) -> ModelError:
    return ModelError(
        f"unsupported {kind} schema version {value!r}; "
        "unsupported notify-wake contract; cutover required"
    )


def _validate_non_negative_integer(value: object, field_name: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        raise ModelError(f"{field_name} must be a non-negative integer")
    return value


def _validate_optional_non_negative_integer(
    value: object,
    field_name: str,
) -> int | None:
    if value is None:
        return None
    return _validate_non_negative_integer(value, field_name)


def goal_objective_sha256(objective: str) -> str:
    return sha256(validate_text(objective, "goal.objective", maximum=4096).encode()).hexdigest()


def validate_goal(value: object, *, expected_status: str | None = None) -> dict[str, Any]:
    if not isinstance(value, Mapping):
        raise ModelError("goal must be an object")
    thread_id = validate_text(value.get("threadId"), "goal.threadId")
    objective = validate_text(value.get("objective"), "goal.objective", maximum=4096)
    status = validate_text(value.get("status"), "goal.status")
    if status not in {
        "active",
        "paused",
        "blocked",
        "usageLimited",
        "budgetLimited",
        "complete",
    }:
        raise ModelError(f"unsupported goal status: {status!r}")
    if expected_status is not None and status != expected_status:
        raise ModelError(f"goal status must be {expected_status!r}")
    return {
        "threadId": thread_id,
        "objective": objective,
        "status": status,
        "tokenBudget": _validate_optional_non_negative_integer(
            value.get("tokenBudget"),
            "goal.tokenBudget",
        ),
        "tokensUsed": _validate_non_negative_integer(value.get("tokensUsed"), "goal.tokensUsed"),
        "timeUsedSeconds": _validate_non_negative_integer(
            value.get("timeUsedSeconds"),
            "goal.timeUsedSeconds",
        ),
        "createdAt": _validate_non_negative_integer(value.get("createdAt"), "goal.createdAt"),
        "updatedAt": _validate_non_negative_integer(value.get("updatedAt"), "goal.updatedAt"),
    }


@dataclass(frozen=True, slots=True)
class WakeContext:
    """Immutable effective authority captured before process launch or attachment."""

    thread_id: str
    permission_profile: str
    approval_policy: object
    captured_at: datetime
    goal_snapshot: dict[str, Any] | None
    schema_version: int = SCHEMA_VERSION

    def __post_init__(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise _unsupported_schema("wake context", self.schema_version)
        object.__setattr__(self, "thread_id", validate_text(self.thread_id, "thread_id"))
        object.__setattr__(
            self,
            "permission_profile",
            validate_text(self.permission_profile, "permission_profile"),
        )
        object.__setattr__(
            self,
            "approval_policy",
            normalize_approval_policy(self.approval_policy),
        )
        object.__setattr__(
            self,
            "captured_at",
            normalize_datetime(self.captured_at, "captured_at"),
        )
        object.__setattr__(
            self,
            "goal_snapshot",
            validate_goal_snapshot(self.goal_snapshot),
        )

    @classmethod
    def from_dict(cls, value: object) -> WakeContext:
        if not isinstance(value, Mapping):
            raise ModelError("wake context must be an object")
        require_exact_fields(value, WAKE_CONTEXT_FIELDS, "wake context")
        captured_at = parse_datetime(value["captured_at"], "captured_at")
        assert captured_at is not None
        return cls(
            schema_version=cast(int, value["schema_version"]),
            thread_id=validate_text(value["thread_id"], "thread_id"),
            permission_profile=validate_text(value["permission_profile"], "permission_profile"),
            approval_policy=value["approval_policy"],
            captured_at=captured_at,
            goal_snapshot=validate_goal_snapshot(value["goal_snapshot"]),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "thread_id": self.thread_id,
            "permission_profile": self.permission_profile,
            "approval_policy": self.approval_policy,
            "captured_at": self.captured_at.isoformat(),
            "goal_snapshot": self.goal_snapshot,
        }

    def resume_params(self) -> dict[str, object]:
        return {
            "threadId": self.thread_id,
            "permissions": self.permission_profile,
            "approvalPolicy": self.approval_policy,
        }


@dataclass(frozen=True, slots=True)
class NotifyWaitLease:
    """Durable proof that notify-wake, rather than the user, blocked one goal."""

    schema_version: int
    lease_id: str
    loop_id: str
    source_ids: tuple[str, ...]
    thread_id: str
    goal_created_at: int
    goal_objective_sha256: str
    goal_token_budget: int | None
    pre_block_updated_at: int
    blocked_goal_updated_at: int | None
    activated_goal_updated_at: int | None
    state: GoalWaitState
    prepared_at: datetime
    blocked_at: datetime | None
    updated_at: datetime
    last_error: str | None

    def __post_init__(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise _unsupported_schema("goal-wait lease", self.schema_version)
        object.__setattr__(self, "lease_id", validate_uuid(self.lease_id, "lease_id"))
        object.__setattr__(self, "loop_id", validate_text(self.loop_id, "loop_id"))
        source_ids = tuple(
            validate_text(source_id, f"source_ids[{index}]")
            for index, source_id in enumerate(self.source_ids)
        )
        if not source_ids:
            raise ModelError("source_ids must not be empty")
        object.__setattr__(self, "source_ids", source_ids)
        object.__setattr__(self, "thread_id", validate_text(self.thread_id, "thread_id"))
        _validate_non_negative_integer(self.goal_created_at, "goal_created_at")
        if not isinstance(self.goal_objective_sha256, str) or not re.fullmatch(
            r"[0-9a-f]{64}", self.goal_objective_sha256
        ):
            raise ModelError("goal_objective_sha256 must be a lowercase SHA-256")
        _validate_optional_non_negative_integer(self.goal_token_budget, "goal_token_budget")
        _validate_non_negative_integer(self.pre_block_updated_at, "pre_block_updated_at")
        _validate_optional_non_negative_integer(
            self.blocked_goal_updated_at,
            "blocked_goal_updated_at",
        )
        _validate_optional_non_negative_integer(
            self.activated_goal_updated_at,
            "activated_goal_updated_at",
        )
        if self.state not in {
            "prepared",
            "blocking_in_flight",
            "owned",
            "activation_in_flight",
            "activated",
            "released",
            "restored",
            "uncertain",
        }:
            raise ModelError(f"unsupported goal-wait state: {self.state!r}")
        object.__setattr__(
            self,
            "prepared_at",
            normalize_datetime(self.prepared_at, "prepared_at"),
        )
        if self.blocked_at is not None:
            object.__setattr__(
                self,
                "blocked_at",
                normalize_datetime(self.blocked_at, "blocked_at"),
            )
        object.__setattr__(self, "updated_at", normalize_datetime(self.updated_at, "updated_at"))
        if self.last_error is not None:
            object.__setattr__(
                self,
                "last_error",
                validate_text(self.last_error, "last_error", maximum=MAX_ERROR_LENGTH),
            )
        if self.state in {
            "owned",
            "activation_in_flight",
            "activated",
            "released",
            "restored",
        } and (self.blocked_goal_updated_at is None or self.blocked_at is None):
            raise ModelError(f"{self.state} goal-wait lease requires a blocked snapshot")
        if self.state in {"activated", "released"} and self.activated_goal_updated_at is None:
            raise ModelError(f"{self.state} goal-wait lease requires an activated snapshot")

    @classmethod
    def prepared(
        cls,
        *,
        lease_id: str,
        loop_id: str,
        source_ids: tuple[str, ...],
        thread_id: str,
        goal: Mapping[str, Any],
        prepared_at: datetime,
    ) -> NotifyWaitLease:
        validated = validate_goal(goal, expected_status="active")
        return cls(
            schema_version=SCHEMA_VERSION,
            lease_id=lease_id,
            loop_id=loop_id,
            source_ids=source_ids,
            thread_id=thread_id,
            goal_created_at=validated["createdAt"],
            goal_objective_sha256=goal_objective_sha256(validated["objective"]),
            goal_token_budget=validated["tokenBudget"],
            pre_block_updated_at=validated["updatedAt"],
            blocked_goal_updated_at=None,
            activated_goal_updated_at=None,
            state="prepared",
            prepared_at=prepared_at,
            blocked_at=None,
            updated_at=prepared_at,
            last_error=None,
        )

    @classmethod
    def owned(
        cls,
        *,
        lease_id: str,
        loop_id: str,
        source_ids: tuple[str, ...],
        thread_id: str,
        goal: Mapping[str, Any],
        prepared_at: datetime,
        blocked_at: datetime,
        pre_block_updated_at: int,
    ) -> NotifyWaitLease:
        validated = validate_goal(goal, expected_status="blocked")
        return cls(
            schema_version=SCHEMA_VERSION,
            lease_id=lease_id,
            loop_id=loop_id,
            source_ids=source_ids,
            thread_id=thread_id,
            goal_created_at=validated["createdAt"],
            goal_objective_sha256=goal_objective_sha256(validated["objective"]),
            goal_token_budget=validated["tokenBudget"],
            pre_block_updated_at=pre_block_updated_at,
            blocked_goal_updated_at=validated["updatedAt"],
            activated_goal_updated_at=None,
            state="owned",
            prepared_at=prepared_at,
            blocked_at=blocked_at,
            updated_at=blocked_at,
            last_error=None,
        )

    def with_state(
        self,
        state: GoalWaitState,
        *,
        updated_at: datetime,
        blocked_goal_updated_at: int | None = None,
        activated_goal_updated_at: int | None = None,
        blocked_at: datetime | None = None,
        last_error: str | None = None,
    ) -> NotifyWaitLease:
        return replace(
            self,
            state=state,
            blocked_goal_updated_at=(
                self.blocked_goal_updated_at
                if blocked_goal_updated_at is None
                else blocked_goal_updated_at
            ),
            activated_goal_updated_at=(
                self.activated_goal_updated_at
                if activated_goal_updated_at is None
                else activated_goal_updated_at
            ),
            blocked_at=self.blocked_at if blocked_at is None else blocked_at,
            updated_at=updated_at,
            last_error=last_error,
        )

    def renew(
        self,
        *,
        blocked_goal_updated_at: int,
        updated_at: datetime,
    ) -> NotifyWaitLease:
        """Record a verified restoration as a fresh owned wait."""

        return replace(
            self,
            state="owned",
            blocked_goal_updated_at=blocked_goal_updated_at,
            activated_goal_updated_at=None,
            updated_at=updated_at,
            last_error=None,
        )

    def matches_goal(self, value: object, *, status: str, updated_at: int) -> bool:
        try:
            goal = validate_goal(value, expected_status=status)
        except ModelError:
            return False
        return (
            goal["threadId"] == self.thread_id
            and goal["createdAt"] == self.goal_created_at
            and goal_objective_sha256(goal["objective"]) == self.goal_objective_sha256
            and goal["tokenBudget"] == self.goal_token_budget
            and goal["updatedAt"] == updated_at
        )

    @classmethod
    def from_dict(cls, value: object) -> NotifyWaitLease:
        if not isinstance(value, Mapping):
            raise ModelError("goal-wait lease must be an object")
        require_exact_fields(value, GOAL_WAIT_LEASE_FIELDS, "goal-wait lease")
        prepared_at = parse_datetime(value["prepared_at"], "prepared_at")
        blocked_at = parse_datetime(value["blocked_at"], "blocked_at", optional=True)
        updated_at = parse_datetime(value["updated_at"], "updated_at")
        assert prepared_at is not None and updated_at is not None
        source_ids = value["source_ids"]
        if not isinstance(source_ids, list):
            raise ModelError("source_ids must be an array")
        return cls(
            schema_version=cast(int, value["schema_version"]),
            lease_id=cast(str, value["lease_id"]),
            loop_id=cast(str, value["loop_id"]),
            source_ids=tuple(cast(list[str], source_ids)),
            thread_id=cast(str, value["thread_id"]),
            goal_created_at=cast(int, value["goal_created_at"]),
            goal_objective_sha256=cast(str, value["goal_objective_sha256"]),
            goal_token_budget=cast(int | None, value["goal_token_budget"]),
            pre_block_updated_at=cast(int, value["pre_block_updated_at"]),
            blocked_goal_updated_at=cast(int | None, value["blocked_goal_updated_at"]),
            activated_goal_updated_at=cast(int | None, value["activated_goal_updated_at"]),
            state=cast(GoalWaitState, value["state"]),
            prepared_at=prepared_at,
            blocked_at=blocked_at,
            updated_at=updated_at,
            last_error=cast(str | None, value["last_error"]),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "lease_id": self.lease_id,
            "loop_id": self.loop_id,
            "source_ids": list(self.source_ids),
            "thread_id": self.thread_id,
            "goal_created_at": self.goal_created_at,
            "goal_objective_sha256": self.goal_objective_sha256,
            "goal_token_budget": self.goal_token_budget,
            "pre_block_updated_at": self.pre_block_updated_at,
            "blocked_goal_updated_at": self.blocked_goal_updated_at,
            "activated_goal_updated_at": self.activated_goal_updated_at,
            "state": self.state,
            "prepared_at": self.prepared_at.isoformat(),
            "blocked_at": isoformat(self.blocked_at),
            "updated_at": self.updated_at.isoformat(),
            "last_error": self.last_error,
        }


@dataclass(frozen=True, slots=True)
class TargetIdentity:
    """Immutable local-process identity."""

    kind: TargetKind
    pid: int
    process_group_id: int | None
    start_ticks: int | None
    identity_method: IdentityMethod

    def __post_init__(self) -> None:
        if self.kind not in {"owned", "attached"}:
            raise ModelError(f"unsupported target kind: {self.kind!r}")
        if not isinstance(self.pid, int) or isinstance(self.pid, bool) or self.pid < 1:
            raise ModelError("pid must be a positive integer")
        for field_name in ("process_group_id", "start_ticks"):
            value = getattr(self, field_name)
            if value is not None and (
                not isinstance(value, int) or isinstance(value, bool) or value < 0
            ):
                raise ModelError(f"{field_name} must be a non-negative integer or null")
        if self.identity_method not in {"parent-handle", "linux-pidfd"}:
            raise ModelError(f"unsupported identity method: {self.identity_method!r}")
        if self.kind == "attached" and (
            self.identity_method != "linux-pidfd" or self.start_ticks is None
        ):
            raise ModelError("attached targets require a Linux pidfd and start_ticks")

    @classmethod
    def from_dict(cls, value: object) -> TargetIdentity:
        if not isinstance(value, Mapping):
            raise ModelError("target must be an object")
        require_exact_fields(value, TARGET_FIELDS, "target")
        return cls(
            kind=cast(TargetKind, value["kind"]),
            pid=cast(int, value["pid"]),
            process_group_id=cast(int | None, value["process_group_id"]),
            start_ticks=cast(int | None, value["start_ticks"]),
            identity_method=cast(IdentityMethod, value["identity_method"]),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "kind": self.kind,
            "pid": self.pid,
            "process_group_id": self.process_group_id,
            "start_ticks": self.start_ticks,
            "identity_method": self.identity_method,
        }


def validate_evidence_paths(values: Iterable[object]) -> tuple[str, ...]:
    return tuple(
        validate_absolute_path(value, f"evidence_paths[{index}]")
        for index, value in enumerate(values)
    )


@dataclass(frozen=True, slots=True)
class WatchRecord:
    """Durable lifecycle and immutable process-watch configuration."""

    schema_version: int
    watch_id: str
    mode: WatchMode
    lifecycle: Lifecycle
    created_at: datetime
    updated_at: datetime
    timeout_seconds: float
    wake_on: WakeOn
    evidence_paths: tuple[str, ...]
    process_log_path: str | None
    target: TargetIdentity | None

    def __post_init__(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise _unsupported_schema("watch", self.schema_version)
        object.__setattr__(self, "watch_id", validate_uuid(self.watch_id, "watch_id"))
        if self.mode not in {"run", "attach"}:
            raise ModelError(f"unsupported watch mode: {self.mode!r}")
        if self.lifecycle not in {"prepared", "armed", "active", "complete", "closed"}:
            raise ModelError(f"unsupported lifecycle: {self.lifecycle!r}")
        object.__setattr__(self, "created_at", normalize_datetime(self.created_at, "created_at"))
        object.__setattr__(self, "updated_at", normalize_datetime(self.updated_at, "updated_at"))
        if (
            not isinstance(self.timeout_seconds, (int, float))
            or isinstance(self.timeout_seconds, bool)
            or not isfinite(self.timeout_seconds)
            or self.timeout_seconds <= 0
        ):
            raise ModelError("timeout_seconds must be finite and positive")
        object.__setattr__(self, "timeout_seconds", float(self.timeout_seconds))
        if self.wake_on not in {"always", "failure"}:
            raise ModelError(f"unsupported wake_on value: {self.wake_on!r}")
        object.__setattr__(self, "evidence_paths", validate_evidence_paths(self.evidence_paths))
        if self.process_log_path is not None:
            object.__setattr__(
                self,
                "process_log_path",
                validate_absolute_path(self.process_log_path, "process_log_path"),
            )
        if self.lifecycle in {"active", "complete", "closed"} and self.target is None:
            raise ModelError(f"{self.lifecycle} watch must include a target")

    @classmethod
    def from_dict(cls, value: object) -> WatchRecord:
        if not isinstance(value, Mapping):
            raise ModelError("watch must be an object")
        require_exact_fields(value, WATCH_FIELDS, "watch")
        created_at = parse_datetime(value["created_at"], "created_at")
        updated_at = parse_datetime(value["updated_at"], "updated_at")
        assert created_at is not None and updated_at is not None
        evidence = value["evidence_paths"]
        if not isinstance(evidence, list):
            raise ModelError("evidence_paths must be an array")
        target = value["target"]
        return cls(
            schema_version=cast(int, value["schema_version"]),
            watch_id=validate_uuid(value["watch_id"], "watch_id"),
            mode=cast(WatchMode, value["mode"]),
            lifecycle=cast(Lifecycle, value["lifecycle"]),
            created_at=created_at,
            updated_at=updated_at,
            timeout_seconds=cast(float, value["timeout_seconds"]),
            wake_on=cast(WakeOn, value["wake_on"]),
            evidence_paths=validate_evidence_paths(evidence),
            process_log_path=cast(str | None, value["process_log_path"]),
            target=TargetIdentity.from_dict(target) if target is not None else None,
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "watch_id": self.watch_id,
            "mode": self.mode,
            "lifecycle": self.lifecycle,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "timeout_seconds": self.timeout_seconds,
            "wake_on": self.wake_on,
            "evidence_paths": list(self.evidence_paths),
            "process_log_path": self.process_log_path,
            "target": self.target.to_dict() if self.target is not None else None,
        }

    def activate(self, target: TargetIdentity, now: datetime) -> WatchRecord:
        return replace(
            self,
            lifecycle="active",
            target=target,
            updated_at=normalize_datetime(now, "updated_at"),
        )

    def with_lifecycle(self, lifecycle: Lifecycle, now: datetime) -> WatchRecord:
        return replace(
            self,
            lifecycle=lifecycle,
            updated_at=normalize_datetime(now, "updated_at"),
        )


@dataclass(frozen=True, slots=True)
class TerminalRecord:
    """Authoritative terminal observation for one process watch."""

    schema_version: int
    watch_id: str
    event_id: str
    target: TargetIdentity
    status: TerminalStatus
    exit_code: int | None
    signal_number: int | None
    occurred_at: datetime
    attention_required: bool
    evidence_paths: tuple[str, ...]

    def __post_init__(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise _unsupported_schema("terminal", self.schema_version)
        object.__setattr__(self, "watch_id", validate_uuid(self.watch_id, "watch_id"))
        object.__setattr__(self, "event_id", validate_uuid(self.event_id, "event_id"))
        if self.status not in {
            "succeeded",
            "failed",
            "signaled",
            "exited",
            "timed_out",
            "identity_lost",
            "monitor_error",
            "cancelled",
        }:
            raise ModelError(f"unsupported terminal status: {self.status!r}")
        for field_name in ("exit_code", "signal_number"):
            value = getattr(self, field_name)
            if value is not None and (
                not isinstance(value, int) or isinstance(value, bool) or value < 0
            ):
                raise ModelError(f"{field_name} must be a non-negative integer or null")
        object.__setattr__(self, "occurred_at", normalize_datetime(self.occurred_at, "occurred_at"))
        if not isinstance(self.attention_required, bool):
            raise ModelError("attention_required must be a boolean")
        object.__setattr__(self, "evidence_paths", validate_evidence_paths(self.evidence_paths))

    @classmethod
    def from_dict(cls, value: object) -> TerminalRecord:
        if not isinstance(value, Mapping):
            raise ModelError("terminal state must be an object")
        require_exact_fields(value, TERMINAL_FIELDS, "terminal state")
        occurred_at = parse_datetime(value["occurred_at"], "occurred_at")
        assert occurred_at is not None
        evidence = value["evidence_paths"]
        if not isinstance(evidence, list):
            raise ModelError("evidence_paths must be an array")
        return cls(
            schema_version=cast(int, value["schema_version"]),
            watch_id=validate_uuid(value["watch_id"], "watch_id"),
            event_id=validate_uuid(value["event_id"], "event_id"),
            target=TargetIdentity.from_dict(value["target"]),
            status=cast(TerminalStatus, value["status"]),
            exit_code=cast(int | None, value["exit_code"]),
            signal_number=cast(int | None, value["signal_number"]),
            occurred_at=occurred_at,
            attention_required=cast(bool, value["attention_required"]),
            evidence_paths=validate_evidence_paths(evidence),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "watch_id": self.watch_id,
            "event_id": self.event_id,
            "target": self.target.to_dict(),
            "status": self.status,
            "exit_code": self.exit_code,
            "signal_number": self.signal_number,
            "occurred_at": self.occurred_at.isoformat(),
            "attention_required": self.attention_required,
            "evidence_paths": list(self.evidence_paths),
        }


@dataclass(frozen=True, slots=True)
class NotificationRecord:
    """Delivery state kept separate from terminal process truth."""

    schema_version: int
    watch_id: str
    event_id: str
    thread_id: str
    state: DeliveryState
    attempt_count: int
    attempted_rpc_method: str | None
    request_sent_at: datetime | None
    uncertainty_reason: str | None
    last_attempt_at: datetime | None
    next_attempt_at: datetime | None
    last_error: str | None
    accepted_at: datetime | None
    accepted_rpc_method: str | None
    accepted_turn_id: str | None

    def __post_init__(self) -> None:
        if self.schema_version != SCHEMA_VERSION:
            raise _unsupported_schema("notification", self.schema_version)
        object.__setattr__(self, "watch_id", validate_uuid(self.watch_id, "watch_id"))
        object.__setattr__(self, "event_id", validate_uuid(self.event_id, "event_id"))
        object.__setattr__(self, "thread_id", validate_text(self.thread_id, "thread_id"))
        if self.state not in {
            "none",
            "pending",
            "in_flight",
            "uncertain",
            "retry_due",
            "accepted",
            "blocked",
        }:
            raise ModelError(f"unsupported delivery state: {self.state!r}")
        if (
            not isinstance(self.attempt_count, int)
            or isinstance(self.attempt_count, bool)
            or self.attempt_count < 0
        ):
            raise ModelError("attempt_count must be a non-negative integer")
        for field_name in (
            "request_sent_at",
            "last_attempt_at",
            "next_attempt_at",
            "accepted_at",
        ):
            value = getattr(self, field_name)
            if value is not None:
                object.__setattr__(self, field_name, normalize_datetime(value, field_name))
        for field_name in ("uncertainty_reason", "last_error"):
            value = getattr(self, field_name)
            if value is not None:
                object.__setattr__(
                    self,
                    field_name,
                    validate_text(value, field_name, maximum=MAX_ERROR_LENGTH),
                )
        for field_name in ("attempted_rpc_method", "accepted_rpc_method", "accepted_turn_id"):
            value = getattr(self, field_name)
            if value is not None:
                object.__setattr__(self, field_name, validate_text(value, field_name))
        if self.state == "accepted" and (
            self.accepted_at is None
            or self.accepted_rpc_method not in {"turn/start", "turn/steer"}
            or self.accepted_turn_id is None
        ):
            raise ModelError("accepted notification lacks acceptance metadata")
        if self.state == "in_flight" and self.request_sent_at is None:
            raise ModelError("in_flight notification lacks request_sent_at")
        if self.state in {"in_flight", "uncertain"} and self.attempted_rpc_method not in {
            "turn/start",
            "turn/steer",
        }:
            raise ModelError(f"{self.state} notification lacks attempted_rpc_method")
        if self.state == "uncertain" and (
            self.request_sent_at is None or self.uncertainty_reason is None
        ):
            raise ModelError("uncertain notification lacks request metadata")
        if self.state == "retry_due" and self.next_attempt_at is None:
            raise ModelError("retry_due notification lacks next_attempt_at")
        if self.state == "retry_due" and (
            (self.request_sent_at is None) != (self.uncertainty_reason is None)
        ):
            raise ModelError("retry_due notification has incomplete request metadata")
        if self.state == "blocked" and self.last_error is None:
            raise ModelError("blocked notification lacks last_error")
        if self.state == "blocked" and (
            (self.request_sent_at is None) != (self.uncertainty_reason is None)
        ):
            raise ModelError("blocked notification has incomplete request metadata")

    @classmethod
    def pending(
        cls,
        *,
        watch_id: str,
        event_id: str,
        thread_id: str,
        attention_required: bool = True,
    ) -> NotificationRecord:
        state: DeliveryState = "pending" if attention_required else "none"
        return cls(
            schema_version=SCHEMA_VERSION,
            watch_id=watch_id,
            event_id=event_id,
            thread_id=thread_id,
            state=state,
            attempt_count=0,
            attempted_rpc_method=None,
            request_sent_at=None,
            uncertainty_reason=None,
            last_attempt_at=None,
            next_attempt_at=None,
            last_error=None,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    @classmethod
    def from_dict(cls, value: object) -> NotificationRecord:
        if not isinstance(value, Mapping):
            raise ModelError("notification must be an object")
        require_exact_fields(value, NOTIFICATION_FIELDS, "notification")
        return cls(
            schema_version=cast(int, value["schema_version"]),
            watch_id=validate_uuid(value["watch_id"], "watch_id"),
            event_id=validate_uuid(value["event_id"], "event_id"),
            thread_id=validate_text(value["thread_id"], "thread_id"),
            state=cast(DeliveryState, value["state"]),
            attempt_count=cast(int, value["attempt_count"]),
            attempted_rpc_method=cast(str | None, value["attempted_rpc_method"]),
            request_sent_at=parse_datetime(
                value["request_sent_at"], "request_sent_at", optional=True
            ),
            uncertainty_reason=cast(str | None, value["uncertainty_reason"]),
            last_attempt_at=parse_datetime(
                value["last_attempt_at"], "last_attempt_at", optional=True
            ),
            next_attempt_at=parse_datetime(
                value["next_attempt_at"], "next_attempt_at", optional=True
            ),
            last_error=cast(str | None, value["last_error"]),
            accepted_at=parse_datetime(value["accepted_at"], "accepted_at", optional=True),
            accepted_rpc_method=cast(str | None, value["accepted_rpc_method"]),
            accepted_turn_id=cast(str | None, value["accepted_turn_id"]),
        )

    def to_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "watch_id": self.watch_id,
            "event_id": self.event_id,
            "thread_id": self.thread_id,
            "state": self.state,
            "attempt_count": self.attempt_count,
            "attempted_rpc_method": self.attempted_rpc_method,
            "request_sent_at": isoformat(self.request_sent_at),
            "uncertainty_reason": self.uncertainty_reason,
            "last_attempt_at": isoformat(self.last_attempt_at),
            "next_attempt_at": isoformat(self.next_attempt_at),
            "last_error": self.last_error,
            "accepted_at": isoformat(self.accepted_at),
            "accepted_rpc_method": self.accepted_rpc_method,
            "accepted_turn_id": self.accepted_turn_id,
        }

    def mark_in_flight(
        self,
        sent_at: datetime,
        *,
        rpc_method: str,
    ) -> NotificationRecord:
        normalized = normalize_datetime(sent_at, "request_sent_at")
        return replace(
            self,
            state="in_flight",
            attempt_count=self.attempt_count + 1,
            attempted_rpc_method=rpc_method,
            request_sent_at=normalized,
            uncertainty_reason=None,
            last_attempt_at=normalized,
            next_attempt_at=None,
            last_error=None,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    def mark_uncertain(
        self,
        *,
        sent_at: datetime,
        reason: str,
        rpc_method: str | None = None,
    ) -> NotificationRecord:
        normalized = normalize_datetime(sent_at, "request_sent_at")
        attempts = self.attempt_count if self.attempt_count > 0 else 1
        return replace(
            self,
            state="uncertain",
            attempt_count=attempts,
            attempted_rpc_method=rpc_method or self.attempted_rpc_method,
            request_sent_at=normalized,
            uncertainty_reason=reason,
            last_attempt_at=normalized,
            next_attempt_at=None,
            last_error=reason,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    def schedule_retry(
        self,
        *,
        attempted_at: datetime,
        error: str,
        next_attempt_at: datetime,
        increment_attempt: bool,
    ) -> NotificationRecord:
        attempts = self.attempt_count + (1 if increment_attempt else 0)
        if attempts >= MAX_DELIVERY_ATTEMPTS:
            return self.mark_blocked(
                attempted_at=attempted_at,
                error=f"delivery attempts exhausted: {error}",
                attempt_count=attempts,
            )
        return replace(
            self,
            state="retry_due",
            attempt_count=attempts,
            attempted_rpc_method=None,
            request_sent_at=None,
            uncertainty_reason=None,
            last_attempt_at=normalize_datetime(attempted_at, "last_attempt_at"),
            next_attempt_at=normalize_datetime(next_attempt_at, "next_attempt_at"),
            last_error=error,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    def mark_blocked(
        self,
        *,
        attempted_at: datetime,
        error: str,
        attempt_count: int | None = None,
    ) -> NotificationRecord:
        return replace(
            self,
            state="blocked",
            attempt_count=self.attempt_count if attempt_count is None else attempt_count,
            attempted_rpc_method=None,
            request_sent_at=None,
            uncertainty_reason=None,
            last_attempt_at=normalize_datetime(attempted_at, "last_attempt_at"),
            next_attempt_at=None,
            last_error=error,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    def mark_reconciliation_blocked(
        self,
        *,
        attempted_at: datetime,
        error: str,
        attempt_count: int | None = None,
    ) -> NotificationRecord:
        if self.request_sent_at is None:
            raise ModelError("reconciliation blocker requires a sent request boundary")
        return replace(
            self,
            state="blocked",
            attempt_count=self.attempt_count if attempt_count is None else attempt_count,
            request_sent_at=self.request_sent_at,
            uncertainty_reason=self.uncertainty_reason or error,
            last_attempt_at=normalize_datetime(attempted_at, "last_attempt_at"),
            next_attempt_at=None,
            last_error=error,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    def schedule_reconciliation_retry(
        self,
        *,
        attempted_at: datetime,
        error: str,
        next_attempt_at: datetime,
    ) -> NotificationRecord:
        if self.request_sent_at is None:
            raise ModelError("reconciliation retry requires a sent request boundary")
        attempts = self.attempt_count + 1
        if attempts >= MAX_DELIVERY_ATTEMPTS:
            return self.mark_reconciliation_blocked(
                attempted_at=attempted_at,
                error=f"reconciliation attempts exhausted: {error}",
                attempt_count=attempts,
            )
        return replace(
            self,
            state="retry_due",
            attempt_count=attempts,
            request_sent_at=self.request_sent_at,
            uncertainty_reason=self.uncertainty_reason or error,
            last_attempt_at=normalize_datetime(attempted_at, "last_attempt_at"),
            next_attempt_at=normalize_datetime(next_attempt_at, "next_attempt_at"),
            last_error=error,
            accepted_at=None,
            accepted_rpc_method=None,
            accepted_turn_id=None,
        )

    @property
    def requires_history_reconciliation(self) -> bool:
        return self.state in {"in_flight", "uncertain"} or (
            self.state in {"retry_due", "blocked"}
            and self.request_sent_at is not None
            and self.uncertainty_reason is not None
        )

    def mark_accepted(
        self,
        *,
        accepted_at: datetime,
        rpc_method: str,
        turn_id: str,
    ) -> NotificationRecord:
        normalized = normalize_datetime(accepted_at, "accepted_at")
        return replace(
            self,
            state="accepted",
            request_sent_at=self.request_sent_at,
            uncertainty_reason=None,
            last_attempt_at=normalized,
            next_attempt_at=None,
            last_error=None,
            accepted_at=normalized,
            accepted_rpc_method=rpc_method,
            accepted_turn_id=turn_id,
        )


def notification_is_due(notification: NotificationRecord, now: datetime) -> bool:
    normalized = normalize_datetime(now, "now")
    return notification.state == "pending" or (
        notification.state == "retry_due"
        and notification.next_attempt_at is not None
        and notification.next_attempt_at <= normalized
    )


def earliest_retry_at(
    notifications: Iterable[NotificationRecord],
) -> datetime | None:
    deadlines = [
        notification.next_attempt_at
        for notification in notifications
        if notification.state == "retry_due" and notification.next_attempt_at is not None
    ]
    return min(deadlines) if deadlines else None
