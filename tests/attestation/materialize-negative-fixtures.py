#!/usr/bin/env python3
"""Materialize checked-in negative attestation fixture mutations."""

from __future__ import annotations

import json
import sys
from pathlib import Path


def matches(value: dict, expected: dict) -> bool:
    return all(value.get(key) == item for key, item in expected.items())


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(f"Usage: {sys.argv[0]} FIXTURE_DIR OUTPUT_DIR")
    fixture_dir = Path(sys.argv[1])
    output_dir = Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)
    cases = json.loads((fixture_dir / "negative-cases.json").read_text(encoding="utf-8"))
    manifest = []

    for case in cases:
        state = json.loads((fixture_dir / case["base"]).read_text(encoding="utf-8"))
        operation = case["operation"]
        if operation == "remove_listener":
            before = len(state["listeners"])
            state["listeners"] = [
                item for item in state["listeners"] if not matches(item, case["match"])
            ]
            if len(state["listeners"]) != before - 1:
                raise RuntimeError(f"{case['name']}: listener mutation cardinality mismatch")
        elif operation == "remove_container":
            before = len(state["containers"])
            state["containers"] = [
                item for item in state["containers"] if not matches(item, case["match"])
            ]
            if len(state["containers"]) != before - 1:
                raise RuntimeError(f"{case['name']}: container mutation cardinality mismatch")
        elif operation == "set_container_field":
            selected = [item for item in state["containers"] if matches(item, case["match"])]
            if len(selected) != 1:
                raise RuntimeError(f"{case['name']}: image mutation cardinality mismatch")
            selected[0][case["field"]] = case["value"]
        elif operation == "append_dns":
            state["dns"][case["host"]].append(case["value"])
        elif operation == "append_listener":
            state["listeners"].append(case["value"])
        elif operation == "append_container":
            state["containers"].append(case["value"])
        else:
            raise RuntimeError(f"{case['name']}: unsupported operation {operation}")

        destination = output_dir / f"{case['name']}.json"
        destination.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        manifest.append(
            {"name": case["name"], "role": case["role"], "path": str(destination)}
        )

    print(json.dumps(manifest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
