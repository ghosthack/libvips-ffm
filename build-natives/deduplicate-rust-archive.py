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


def member_basename(name: str) -> str:
    """Return a basename for GNU ar members containing either path style."""
    return name.replace("\\", "/").rsplit("/", 1)[-1]


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: deduplicate-rust-archive.py ARCHIVE")
    archive = Path(sys.argv[1])
    archive_members = members(archive)
    counts = Counter(member_basename(name) for name in archive_members)
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
    for basename in sorted(duplicates):
        matching = [
            name for name in archive_members if member_basename(name) == basename
        ]
        if matching[0] == matching[1]:
            subprocess.run(
                ["ar", "dN", "1", archive, matching[0]], check=True
            )
        else:
            # Rust's MinGW archive builder can retain each import member's
            # temporary-directory prefix. GNU ar's P modifier is required to
            # select one full-path member without deleting its basename twin.
            subprocess.run(["ar", "dP", archive, matching[0]], check=True)

    remaining = Counter(member_basename(name) for name in members(archive))
    if any(count > 1 for count in remaining.values()):
        raise RuntimeError("duplicate members remain after archive repair")
    print(
        "Removed duplicate MinGW kernel32 import members from "
        f"{archive.name}"
    )


if __name__ == "__main__":
    main()
