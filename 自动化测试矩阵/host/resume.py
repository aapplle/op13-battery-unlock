#!/usr/bin/env python3
"""Reuse PASS results only from the latest completed, identical test environment."""
import json
import re
import sys
from pathlib import Path

FIELDS = (
    "device", "device_model", "device_rom", "device_kernel", "device_chgko_md5",
    "boot_route", "tested_zip_sha256", "runner_sha256", "floor", "with_reboot",
    "no_reboot",
)


def resume_ids(results, current, identity):
    reports = [p for p in Path(results).glob("*/report.json")
               if p.parent.resolve() != Path(current).resolve()]
    if not reports:
        return []
    latest = max(reports, key=lambda p: (p.stat().st_mtime_ns, str(p)))
    try:
        report = json.loads(latest.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(report, dict):
        return []
    if any(value in ("", "?", "unknown") or str(report.get(key, "")) != value
           for key, value in identity.items()):
        return []
    rows = report.get("asserts", [])
    if not isinstance(rows, list):
        return []
    # A case may have many assertion rows. Any non-PASS row prevents reuse.
    status = {}
    for row in rows:
        if not isinstance(row, dict):
            return []
        case = row.get("case", "")
        if not isinstance(case, str) or not re.fullmatch(r"T(?:\d+|D)\.\d+", case):
            continue
        result = row.get("result")
        if not isinstance(result, str):
            return []
        status.setdefault(case, set()).add(result)
    return sorted(case for case, values in status.items() if values == {"PASS"})


def main():
    if len(sys.argv) != 3 + len(FIELDS):
        raise SystemExit("resume.py: expected results/current directories and environment identity")
    identity = dict(zip(FIELDS, sys.argv[3:]))
    print(" ".join(resume_ids(sys.argv[1], sys.argv[2], identity)))


if __name__ == "__main__":
    main()
