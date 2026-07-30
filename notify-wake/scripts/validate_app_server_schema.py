#!/usr/bin/env python3
"""Validate the Codex app-server schema fields used by notify-wake v2."""

from __future__ import annotations

import argparse
import json
from collections.abc import Mapping
from pathlib import Path
from typing import Any


class SchemaError(ValueError):
    """The generated app-server schema does not satisfy the runtime contract."""


METHOD_FIELDS: dict[str, tuple[frozenset[str], frozenset[str]]] = {
    "ThreadResumeParams": (
        frozenset({"threadId"}),
        frozenset({"threadId", "approvalPolicy"}),
    ),
    "ThreadResumeResponse": (
        frozenset({"thread", "approvalPolicy"}),
        frozenset({"thread", "approvalPolicy"}),
    ),
    "ThreadGoalGetParams": (
        frozenset({"threadId"}),
        frozenset({"threadId"}),
    ),
    "ThreadGoalGetResponse": (
        frozenset(),
        frozenset({"goal"}),
    ),
    "ThreadGoalSetParams": (
        frozenset({"threadId"}),
        frozenset({"threadId", "status"}),
    ),
    "ThreadGoalSetResponse": (
        frozenset({"goal"}),
        frozenset({"goal"}),
    ),
    "ThreadReadParams": (
        frozenset({"threadId"}),
        frozenset({"threadId", "includeTurns"}),
    ),
    "ThreadReadResponse": (
        frozenset({"thread"}),
        frozenset({"thread"}),
    ),
    "TurnStartParams": (
        frozenset({"threadId", "input"}),
        frozenset({"threadId", "input", "clientUserMessageId", "model", "effort"}),
    ),
    "TurnStartResponse": (
        frozenset({"turn"}),
        frozenset({"turn"}),
    ),
    "TurnSteerParams": (
        frozenset({"threadId", "input", "expectedTurnId"}),
        frozenset({"threadId", "input", "expectedTurnId", "clientUserMessageId"}),
    ),
    "TurnSteerResponse": (
        frozenset({"turnId"}),
        frozenset({"turnId"}),
    ),
}
GOAL_FIELDS = frozenset(
    {
        "threadId",
        "objective",
        "status",
        "tokenBudget",
        "tokensUsed",
        "timeUsedSeconds",
        "createdAt",
        "updatedAt",
    }
)
REQUIRED_GOAL_FIELDS = GOAL_FIELDS - {"tokenBudget"}


def _load_object(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SchemaError(f"{path.name} is not valid JSON: {error}") from error
    if not isinstance(value, dict):
        raise SchemaError(f"{path.name} must contain a JSON object")
    return value


def _string_set(value: object, source: str) -> frozenset[str]:
    if value is None:
        return frozenset()
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise SchemaError(f"{source} must be an array of strings")
    return frozenset(value)


def _property_names(schema: Mapping[str, Any], source: str) -> frozenset[str]:
    properties = schema.get("properties")
    if not isinstance(properties, Mapping) or not all(isinstance(name, str) for name in properties):
        raise SchemaError(f"{source}.properties must be an object")
    return frozenset(properties)


def validate_schema(schema_root: Path) -> None:
    """Validate generated v2 method and persistent-goal schema fields."""

    v2_root = schema_root / "v2"
    for schema_name, (required_fields, property_fields) in METHOD_FIELDS.items():
        schema = _load_object(v2_root / f"{schema_name}.json")
        actual_required = _string_set(schema.get("required"), f"{schema_name}.required")
        actual_properties = _property_names(schema, schema_name)
        if not required_fields <= actual_required:
            missing = sorted(required_fields - actual_required)
            raise SchemaError(f"{schema_name} lacks required fields: {missing}")
        if not property_fields <= actual_properties:
            missing = sorted(property_fields - actual_properties)
            raise SchemaError(f"{schema_name} lacks properties: {missing}")

    goal_response = _load_object(v2_root / "ThreadGoalSetResponse.json")
    definitions = goal_response.get("definitions")
    if not isinstance(definitions, Mapping):
        raise SchemaError("ThreadGoalSetResponse lacks definitions")
    goal = definitions.get("ThreadGoal")
    if not isinstance(goal, Mapping):
        raise SchemaError("ThreadGoalSetResponse lacks the ThreadGoal definition")
    goal_required = _string_set(goal.get("required"), "ThreadGoal.required")
    goal_properties = _property_names(goal, "ThreadGoal")
    if not goal_required >= REQUIRED_GOAL_FIELDS:
        missing = sorted(REQUIRED_GOAL_FIELDS - goal_required)
        raise SchemaError(f"ThreadGoal lacks required fields: {missing}")
    if not goal_properties >= GOAL_FIELDS:
        missing = sorted(GOAL_FIELDS - goal_properties)
        raise SchemaError(f"ThreadGoal lacks properties: {missing}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("schema_root", type=Path)
    arguments = parser.parse_args()
    validate_schema(arguments.schema_root)
    print("notify-wake app-server schema contract is valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
