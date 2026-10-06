#!/usr/bin/env python3
"""Resolve capability classes from the installed Codex model catalog."""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import signal
import sys
from pathlib import Path
from typing import Any, cast

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.render_codex_agents import (  # noqa: E402
    CATALOG_PATH,
    expand_catalog,
    load_catalog,
    require_table,
)

MESSAGE_LIMIT = 16 * 1024 * 1024
MODEL_PATTERN = re.compile(r"^gpt-([0-9]+(?:\.[0-9]+)*)-([a-z]+)$")


def validate_model_list(value: object, *, complete: bool = True) -> dict[str, Any]:
    """Require complete, unambiguous model evidence without exposing its content."""
    result = require_table(value, "model list")
    data = result.get("data")
    if not isinstance(data, list) or "nextCursor" not in result:
        raise ValueError("model list requires data and nextCursor")
    cursor = result["nextCursor"]
    if cursor is not None and (not isinstance(cursor, str) or not cursor):
        raise ValueError("model list has an invalid cursor")
    if complete and cursor is not None:
        raise ValueError("saved model list is incomplete")
    names: set[str] = set()
    for row in data:
        entry = require_table(row, "model entry")
        name = entry.get("model")
        if (
            not isinstance(name, str)
            or not name
            or type(entry.get("hidden")) is not bool
        ):
            raise ValueError("model entry requires model and hidden")
        if name in names:
            raise ValueError("model list has duplicate model IDs")
        names.add(name)
        efforts = entry.get("supportedReasoningEfforts")
        if not isinstance(efforts, list) or not efforts:
            raise ValueError("model entry requires supported reasoning efforts")
        for effort in efforts:
            item = require_table(effort, "reasoning effort")
            if (
                not isinstance(item.get("reasoningEffort"), str)
                or not item["reasoningEffort"]
            ):
                raise ValueError("model entry has an invalid reasoning effort")
    return result


def load_model_list(path: Path) -> dict[str, Any]:
    """Load explicitly supplied evidence with the same size bound as discovery."""
    with path.open("rb") as source:
        content = source.read(MESSAGE_LIMIT + 1)
    if len(content) > MESSAGE_LIMIT:
        raise ValueError("saved model list exceeds 16 MiB")
    try:
        value: object = json.loads(content)
    except (ValueError, UnicodeError) as error:
        raise ValueError("saved model list is invalid JSON") from error
    return validate_model_list(value)


def resolve_models(
    catalog: dict[str, Any], evidence: dict[str, Any], pins: list[str] | None = None
) -> dict[str, str]:
    """Select the newest visible stable family member, then check required efforts."""
    data = validate_model_list(evidence)["data"]
    capabilities = require_table(catalog.get("capabilities"), "capabilities")
    classes = require_table(catalog.get("classes"), "classes")
    overrides: dict[str, str] = {}
    for pin in pins or []:
        capability, separator, name = pin.partition("=")
        if not separator or not name or capability not in capabilities:
            raise ValueError("pin must be a known CAPABILITY=MODEL_ID")
        if capability in overrides:
            raise ValueError(f"duplicate model pin for {capability}")
        overrides[capability] = name

    resolved: dict[str, str] = {}
    for capability, settings in capabilities.items():
        family = require_table(settings, f"capabilities.{capability}").get("family")
        if not isinstance(family, str) or re.fullmatch(r"[a-z]+", family) is None:
            raise ValueError(f"capabilities.{capability} requires a family")
        candidates: list[tuple[tuple[int, ...], str, dict[str, Any]]] = []
        for raw_entry in data:
            entry = require_table(raw_entry, "model entry")
            name = cast(str, entry["model"])
            match = MODEL_PATTERN.fullmatch(name)
            if entry["hidden"] or match is None or match[2] != family:
                continue
            if capability in overrides and name != overrides[capability]:
                continue
            version = tuple(int(part) for part in match[1].split("."))
            candidates.append((version, name, entry))
        if not candidates:
            raise ValueError(
                f"no visible stable model for {capability} (family {family}) or its pin"
            )
        _, selected, entry = max(candidates, key=lambda item: (item[0], item[1]))
        supported = {
            item["reasoningEffort"] for item in entry["supportedReasoningEfforts"]
        }
        required = {
            agent["model_reasoning_effort"]
            for agent in classes.values()
            if agent["capability"] == capability
        }
        missing = required - supported
        if missing:
            raise ValueError(
                f"{capability} model {selected} does not support {', '.join(sorted(missing))}"
            )
        resolved[capability] = selected
    return resolved


async def _discover_models(
    command: tuple[str, ...], timeout: float, max_pages: int, message_limit: int
) -> dict[str, Any]:
    process: asyncio.subprocess.Process | None = None
    try:
        async with asyncio.timeout(timeout):
            process = await asyncio.create_subprocess_exec(
                *command,
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
                limit=message_limit + 1,
                start_new_session=os.name == "posix",
            )
            assert process.stdin is not None and process.stdout is not None
            writer, reader = process.stdin, process.stdout

            async def send(message: dict[str, Any]) -> None:
                writer.write(json.dumps(message).encode() + b"\n")
                await writer.drain()

            async def request(
                request_id: int, method: str, params: dict[str, Any]
            ) -> dict[str, Any]:
                await send({"id": request_id, "method": method, "params": params})
                while True:
                    try:
                        line = await reader.readline()
                    except ValueError as error:
                        raise ValueError(
                            "app-server message exceeds size limit"
                        ) from error
                    if not line:
                        raise ValueError("app server exited before responding")
                    if len(line) > message_limit:
                        raise ValueError("app-server message exceeds size limit")
                    try:
                        decoded: object = json.loads(line)
                    except (ValueError, UnicodeError) as error:
                        raise ValueError("app server returned invalid JSON") from error
                    message = require_table(decoded, "app-server message")
                    if "method" in message:
                        if "id" in message:
                            await send(
                                {
                                    "id": message["id"],
                                    "error": {
                                        "code": -32601,
                                        "message": "Unsupported server request",
                                    },
                                }
                            )
                        continue
                    if (
                        type(message.get("id")) is not int
                        or message["id"] != request_id
                    ):
                        raise ValueError(
                            "app server returned an unexpected response ID"
                        )
                    if "error" in message:
                        raise ValueError(f"app server rejected {method}")
                    return require_table(message.get("result"), "app-server result")

            await request(
                1,
                "initialize",
                {
                    "clientInfo": {
                        "name": "skills_model_resolver",
                        "version": "1.0",
                    }
                },
            )
            await send({"method": "initialized"})
            combined: list[Any] = []
            seen: set[str] = set()
            cursor: str | None = None
            for page in range(max_pages):
                params: dict[str, Any] = {"limit": 100, "includeHidden": False}
                if cursor is not None:
                    params["cursor"] = cursor
                result = validate_model_list(
                    await request(page + 2, "model/list", params), complete=False
                )
                combined.extend(result["data"])
                complete = {"data": combined, "nextCursor": None}
                if len(json.dumps(complete).encode()) > MESSAGE_LIMIT:
                    raise ValueError("complete model list exceeds 16 MiB")
                cursor = result["nextCursor"]
                if cursor is None:
                    return validate_model_list(complete)
                if cursor in seen:
                    raise ValueError("app server repeated a pagination cursor")
                seen.add(cursor)
            raise ValueError("model discovery exceeded page limit")
    except TimeoutError as error:
        raise ValueError("model discovery timed out") from error
    except (OSError, ConnectionError) as error:
        raise ValueError("could not communicate with the Codex app server") from error
    finally:
        if process is not None:
            if os.name == "posix":
                try:
                    os.killpg(process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            elif process.returncode is None:
                process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=2)
            except TimeoutError:
                if os.name == "posix":
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                else:
                    process.kill()
                await process.wait()


def discover_models(
    *,
    command: tuple[str, ...] = ("codex", "app-server", "--listen", "stdio://"),
    timeout: float = 30,
    max_pages: int = 100,
    message_limit: int = MESSAGE_LIMIT,
) -> dict[str, Any]:
    """Read every model page within one deadline and stop the child process."""
    return asyncio.run(_discover_models(command, timeout, max_pages, message_limit))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--catalog", type=Path, default=CATALOG_PATH)
    parser.add_argument("--model-list", type=Path)
    parser.add_argument("--save-model-list", type=Path)
    parser.add_argument("--pin-model", action="append", default=[])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        catalog = load_catalog(args.catalog)
        expand_catalog(catalog)
        evidence = (
            load_model_list(args.model_list) if args.model_list else discover_models()
        )
        resolved = resolve_models(catalog, evidence, args.pin_model)
        source = (
            f"supplied model-list file {args.model_list} (availability not verified)"
            if args.model_list
            else "installed Codex model/list"
        )
        print(f"Model evidence: {source}")
        for capability, name in resolved.items():
            efforts = sorted(
                {
                    agent["model_reasoning_effort"]
                    for agent in catalog["classes"].values()
                    if agent["capability"] == capability
                }
            )
            pinned = (
                " (pinned for this invocation)"
                if any(pin.startswith(capability + "=") for pin in args.pin_model)
                else ""
            )
            print(
                f"{capability}: {name}; reasoning efforts: {', '.join(efforts)}{pinned}"
            )
        args.output.write_text(json.dumps(resolved, indent=2) + "\n", encoding="utf-8")
        if args.save_model_list:
            args.save_model_list.write_text(
                json.dumps(evidence, indent=2) + "\n", encoding="utf-8"
            )
        return 0
    except (OSError, ValueError, TypeError, KeyError) as error:
        print(f"Error: cannot resolve Codex models: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
