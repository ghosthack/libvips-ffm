#!/usr/bin/env python3
"""Remove duplicate MinGW import members emitted into a Rust static archive."""

from __future__ import annotations

from collections import Counter
from pathlib import Path
import subprocess
import sys


EXPECTED_DUPLICATES = {
    "kernel32.dllh.o",
    "kernel32.dlls00000.o",
    "kernel32.dlls00001.o",
    "kernel32.dlls00002.o",
    "kernel32.dlls00003.o",
    "kernel32.dlls00004.o",
    "kernel32.dllt.o",
}


def members(archive: Path) -> list[str]:
    result = subprocess.run(
        ["ar", "t", archive],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return [line for line in result.stdout.splitlines() if line]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: deduplicate-rust-archive.py ARCHIVE")
    archive = Path(sys.argv[1])
    counts = Counter(members(archive))
    duplicates = {name for name, count in counts.items() if count > 1}
    if not duplicates:
        print(f"{archive.name} has already been deduplicated")
        return
    if duplicates != EXPECTED_DUPLICATES:
        raise RuntimeError(
            "unexpected duplicate archive members: "
            f"expected {sorted(EXPECTED_DUPLICATES)}, got {sorted(duplicates)}"
        )
    if any(counts[name] != 2 for name in duplicates):
        raise RuntimeError(
            "expected exactly two copies of each duplicate import member"
        )

    # GNU ar's N modifier addresses a numbered occurrence. Keep the second
    # block: it owns additional, uniquely named import thunks later in the
    # archive which reference that block's header and trailer members.
    for name in sorted(duplicates):
        subprocess.run(["ar", "dN", "1", archive, name], check=True)

    remaining = Counter(members(archive))
    if any(count > 1 for count in remaining.values()):
        raise RuntimeError("duplicate members remain after archive repair")
    print(
        "Removed duplicate MinGW kernel32 import members from "
        f"{archive.name}"
    )


if __name__ == "__main__":
    main()
