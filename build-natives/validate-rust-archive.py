#!/usr/bin/env python3
"""Validate reviewed MinGW duplicates without invoking archive tools."""

from __future__ import annotations

from collections import Counter
from pathlib import Path
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

AR_MAGIC = b"!<arch>\n"
HEADER_SIZE = 60


def member_basename(name: str) -> str:
    """Return a basename for archive members containing either path style."""
    return name.replace("\\", "/").rsplit("/", 1)[-1]


def gnu_long_name(table: bytes, offset: int) -> str:
    if offset >= len(table):
        raise RuntimeError(f"invalid GNU archive name offset: {offset}")
    end = table.find(b"/\n", offset)
    if end < 0:
        end = table.find(b"\x00", offset)
    if end < 0:
        end = len(table)
    return table[offset:end].decode("utf-8", errors="surrogateescape")


def members(archive: Path) -> list[str]:
    names: list[str] = []
    long_names = b""
    with archive.open("rb") as stream:
        if stream.read(len(AR_MAGIC)) != AR_MAGIC:
            raise RuntimeError(f"{archive} is not a regular ar archive")
        while True:
            header = stream.read(HEADER_SIZE)
            if not header:
                break
            if len(header) != HEADER_SIZE or header[58:60] != b"`\n":
                raise RuntimeError(f"malformed ar header in {archive}")
            try:
                size = int(header[48:58].decode("ascii").strip())
            except ValueError as error:
                raise RuntimeError(f"invalid ar member size in {archive}") from error
            raw_name = header[:16].decode("ascii", errors="surrogateescape").rstrip()
            data_offset = stream.tell()

            if raw_name == "//":
                long_names = stream.read(size)
            elif raw_name in {"/", "/SYM64/"}:
                stream.seek(size, 1)
            elif raw_name.startswith("/") and raw_name[1:].isdigit():
                names.append(gnu_long_name(long_names, int(raw_name[1:])))
                stream.seek(size, 1)
            elif raw_name.startswith("#1/"):
                name_size = int(raw_name[3:])
                names.append(
                    stream.read(name_size).decode("utf-8", errors="surrogateescape")
                )
                stream.seek(size - name_size, 1)
            else:
                names.append(raw_name.removesuffix("/"))
                stream.seek(size, 1)

            if stream.tell() != data_offset + size:
                raise RuntimeError(f"invalid ar member bounds in {archive}")
            if size % 2:
                if stream.read(1) != b"\n":
                    raise RuntimeError(f"invalid ar member padding in {archive}")
    return names


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: validate-rust-archive.py ARCHIVE")
    archive = Path(sys.argv[1])
    counts = Counter(member_basename(name) for name in members(archive))
    duplicates = {name for name, count in counts.items() if count > 1}
    if duplicates != EXPECTED_DUPLICATES:
        raise RuntimeError(
            "unexpected duplicate archive members: "
            f"expected {sorted(EXPECTED_DUPLICATES)}, got {sorted(duplicates)}"
        )
    if any(counts[name] != 2 for name in duplicates):
        raise RuntimeError(
            "expected exactly two copies of each duplicate import member"
        )
    print(
        "Validated duplicate MinGW kernel32 import members in "
        f"{archive.name}"
    )


if __name__ == "__main__":
    main()
