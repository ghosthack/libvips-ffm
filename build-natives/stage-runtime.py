#!/usr/bin/env python3
"""Stage and relocate the shared-library closure built for one classifier."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def run(*args: str) -> str:
    return subprocess.run(
        args, check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def is_library(platform: str, path: Path) -> bool:
    name = path.name.lower()
    if platform == "windows-x64":
        return name.endswith(".dll")
    if platform == "macos-arm64":
        return name.endswith(".dylib")
    return name.endswith(".so") or ".so." in name


def copy_library(source: Path, destination: Path) -> None:
    target = destination / source.name
    resolved = source.resolve()
    if target.exists():
        if target.read_bytes() != resolved.read_bytes():
            raise RuntimeError(f"conflicting runtime library name: {source.name}")
        return
    shutil.copy2(resolved, target)


def neutral_path(original: bytes) -> bytes:
    """Return a same-length, deliberately nonexistent build-path marker."""
    if len(original) < 11:
        raise RuntimeError(f"cannot safely neutralize short build path: {original!r}")
    if len(original) >= 3 and original[1:3] in (b":/", b":\\"):
        separator = original[2:3]
        marker = b"X:" + separator + b"__lvffm__"
    else:
        marker = b"/__lvffm__"
    return (marker + b"_" * len(original))[:len(original)]


def sanitize_build_paths(destination: Path, roots: list[Path]) -> None:
    """Remove developer-machine paths embedded as compiled-in defaults/debug data."""
    project_root = roots[0].parents[2]
    originals: set[bytes] = set()
    for path in (*roots, project_root, Path.home()):
        text = str(path)
        slash_spelling = text.replace("\\", "/")
        spellings = {
            text,
            slash_spelling,
            text.replace("/", "\\"),
        }
        if re.match(r"^[A-Za-z]:/", slash_spelling):
            suffix = slash_spelling[2:]
            drive = slash_spelling[0]
            spellings.add(f"/{drive.lower()}{suffix}")
            spellings.add(f"/{drive.upper()}{suffix}")
        for spelling in spellings:
            encoded = spelling.encode()
            if len(encoded) >= 11:
                originals.add(encoded)

    ordered = sorted(originals, key=len, reverse=True)
    for library in destination.iterdir():
        if not library.is_file():
            continue
        contents = library.read_bytes()
        updated = contents
        for original in ordered:
            updated = updated.replace(original, neutral_path(original))
        if updated != contents:
            library.write_bytes(updated)
        for original in ordered:
            if original in updated:
                raise RuntimeError(
                    f"{library.name}: embedded build path was not neutralized"
                )


def dependencies(platform: str, library: Path) -> list[str]:
    if platform == "macos-arm64":
        return [
            line.strip().split(" ", 1)[0]
            for line in run("otool", "-L", str(library)).splitlines()[1:]
            if line.strip()
        ]
    if platform == "linux-x64":
        return re.findall(
            r"\(NEEDED\).*Shared library: \[([^\]]+)\]",
            run("readelf", "-d", str(library)),
        )
    if platform == "windows-x64":
        return re.findall(
            r"DLL Name:\s*(\S+)",
            run("objdump", "-p", str(library)),
            flags=re.IGNORECASE,
        )
    raise RuntimeError(f"unsupported platform: {platform}")


def main_library_candidate(platform: str, candidates: list[Path]) -> Path:
    if platform == "windows-x64":
        matches = [
            path for path in candidates
            if path.name.lower() == "libvips-42.dll"
        ]
    elif platform == "macos-arm64":
        matches = [
            path for path in candidates
            if path.name.startswith("libvips")
            and path.name.endswith(".dylib")
            and "cpp" not in path.name
        ]
    else:
        matches = [
            path for path in candidates
            if path.name.startswith("libvips.so.")
            and "cpp" not in path.name
        ]
    if not matches:
        raise RuntimeError("build prefix does not contain the libvips C library")
    return sorted(matches, key=lambda path: len(path.name), reverse=True)[0]


def runtime_closure(platform: str, candidates: list[Path]) -> tuple[list[Path], str]:
    by_name: dict[str, Path] = {}
    for candidate in sorted(candidates, key=lambda path: path.name.lower()):
        key = candidate.name.lower()
        previous = by_name.get(key)
        if previous is not None:
            if previous.resolve().read_bytes() != candidate.resolve().read_bytes():
                raise RuntimeError(
                    f"conflicting runtime library name: {candidate.name}"
                )
            continue
        by_name[key] = candidate

    main = main_library_candidate(platform, candidates)
    selected: dict[str, Path] = {}
    pending = [main]
    while pending:
        library = pending.pop()
        key = library.name.lower()
        if key in selected:
            continue
        selected[key] = library
        for dependency in dependencies(platform, library.resolve()):
            dependency_name = Path(dependency).name.lower()
            candidate = by_name.get(dependency_name)
            if candidate is not None and dependency_name not in selected:
                pending.append(candidate)
    return (
        sorted(selected.values(), key=lambda path: path.name.lower()),
        main.name,
    )


def macos_relocate(destination: Path) -> None:
    names = {path.name for path in destination.iterdir() if path.is_file()}
    for library in sorted(destination.iterdir()):
        if not library.is_file() or not library.name.endswith(".dylib"):
            continue
        subprocess.run(
            ["install_name_tool", "-id", f"@loader_path/{library.name}", library],
            check=True,
        )
        for line in run("otool", "-L", str(library)).splitlines()[1:]:
            dependency = line.strip().split(" ", 1)[0]
            basename = Path(dependency).name
            if basename in names and dependency != f"@loader_path/{basename}":
                subprocess.run(
                    [
                        "install_name_tool",
                        "-change",
                        dependency,
                        f"@loader_path/{basename}",
                        library,
                    ],
                    check=True,
                )
        subprocess.run(
            ["codesign", "--force", "--sign", "-", library],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


def linux_relocate(destination: Path) -> None:
    for library in sorted(destination.iterdir()):
        if library.is_file() and (
            library.name.endswith(".so") or ".so." in library.name
        ):
            subprocess.run(
                ["patchelf", "--set-rpath", "$ORIGIN", library], check=True
            )


def strip_runtime(platform: str, destination: Path) -> None:
    if platform == "windows-x64":
        candidates = ("x86_64-w64-mingw32-strip", "strip")
    elif platform == "linux-x64":
        candidates = ("strip",)
    else:
        return

    strip_tool = next(
        (resolved for name in candidates if (resolved := shutil.which(name))),
        None,
    )
    if strip_tool is None:
        raise RuntimeError(
            f"no target strip tool found for {platform}: "
            + ", ".join(candidates)
        )

    libraries = sorted(
        path
        for path in destination.iterdir()
        if path.is_file() and is_library(platform, path)
    )
    before = sum(path.stat().st_size for path in libraries)
    for library in libraries:
        subprocess.run(
            [strip_tool, "--strip-unneeded", str(library)], check=True
        )
    after = sum(path.stat().st_size for path in libraries)
    if after > before:
        raise RuntimeError(
            f"stripping {platform} runtime grew from {before} to {after} bytes"
        )
    print(
        f"Stripped {len(libraries)} {platform} libraries: "
        f"{before} -> {after} bytes ({before - after} saved)"
    )


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    if len(sys.argv) < 5:
        raise SystemExit(
            "usage: stage-runtime.py PLATFORM DEST PREFIX VCPKG_PREFIX"
        )
    platform = sys.argv[1]
    destination = Path(sys.argv[2]).resolve()
    roots = [Path(value).resolve() for value in sys.argv[3:]]
    if destination.name != platform:
        raise RuntimeError(
            f"refusing to replace classifier directory {destination}: "
            f"expected final component {platform}"
        )

    candidates: list[Path] = []
    for root in roots:
        for directory in (root / "bin", root / "lib"):
            if directory.is_dir():
                candidates.extend(
                    path
                    for path in directory.rglob("*")
                    if path.is_file() and is_library(platform, path)
                )

    selected, main_library = runtime_closure(platform, candidates)
    if destination.exists():
        shutil.rmtree(destination)
    destination.mkdir(parents=True, exist_ok=True)
    for candidate in selected:
        copy_library(candidate, destination)

    sanitize_build_paths(destination, roots)

    if platform == "macos-arm64":
        macos_relocate(destination)
    elif platform == "linux-x64":
        linux_relocate(destination)
        strip_runtime(platform, destination)
    elif platform == "windows-x64":
        strip_runtime(platform, destination)
    else:
        raise RuntimeError(f"unsupported platform: {platform}")

    libraries = sorted(
        path.name
        for path in destination.iterdir()
        if path.is_file() and is_library(platform, path)
    )
    (destination / "manifest.txt").write_text(
        "".join(f"{name}\n" for name in libraries),
        encoding="utf-8",
        newline="\n",
    )
    (destination / "main-library.txt").write_text(
        f"{main_library}\n", encoding="utf-8", newline="\n"
    )
    (destination / "manifest.sha256").write_text(
        "".join(
            f"{sha256(destination / name)}  {name}\n" for name in libraries
        ),
        encoding="utf-8",
        newline="\n",
    )


if __name__ == "__main__":
    main()
