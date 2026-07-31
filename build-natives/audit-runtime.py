#!/usr/bin/env python3
"""Reject undeclared native imports and known unwanted integration stacks."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys


FORBIDDEN_CONTENT_MARKERS = (b"sharp-libvips",)
FORBIDDEN_LIBRARY_MARKERS = (
    "magickcore",
    "magickwand",
    "graphicsmagick",
    "libmagick",
    "sharp-libvips",
)

LINUX_PLATFORM_LIBRARIES = {
    "ld-linux-x86-64.so.2",
    "libatomic.so.1",
    "libc.so.6",
    "libdl.so.2",
    "libgcc_s.so.1",
    "libm.so.6",
    "libpthread.so.0",
    "libresolv.so.2",
    "librt.so.1",
    "libstdc++.so.6",
    "libutil.so.1",
}

WINDOWS_PLATFORM_LIBRARIES = {
    "advapi32.dll", "bcrypt.dll", "cfgmgr32.dll", "comctl32.dll",
    "bcryptprimitives.dll", "comdlg32.dll", "crypt32.dll", "d3d11.dll",
    "dbghelp.dll", "dnsapi.dll", "dwrite.dll", "dxgi.dll", "fwpuclnt.dll",
    "gdi32.dll", "imm32.dll",
    "iphlpapi.dll", "kernel32.dll", "msvcp140.dll", "msvcrt.dll", "ncrypt.dll",
    "msimg32.dll", "mswsock.dll", "normaliz.dll", "ntdll.dll", "ole32.dll",
    "oleaut32.dll",
    "powrprof.dll", "propsys.dll", "psapi.dll", "rpcrt4.dll",
    "secur32.dll", "setupapi.dll", "shell32.dll", "shlwapi.dll",
    "ucrtbase.dll", "user32.dll", "userenv.dll", "uuid.dll",
    "version.dll", "vcruntime140.dll", "vcruntime140_1.dll", "winhttp.dll",
    "windows.networking.dll", "winmm.dll", "wintrust.dll", "ws2_32.dll",
}


def output(*args: str) -> str:
    return subprocess.run(
        args, check=True, text=True, stdout=subprocess.PIPE
    ).stdout


def dependencies(platform: str, library: Path) -> list[str]:
    if platform == "macos-arm64":
        result = []
        for line in output("otool", "-L", str(library)).splitlines()[1:]:
            value = line.strip().split(" ", 1)[0]
            if value:
                result.append(value)
        return result
    if platform == "linux-x64":
        return re.findall(
            r"\(NEEDED\).*Shared library: \[([^\]]+)\]",
            output("readelf", "-d", str(library)),
        )
    if platform == "windows-x64":
        return re.findall(
            r"DLL Name:\s*(\S+)",
            output("objdump", "-p", str(library)),
            flags=re.IGNORECASE,
        )
    raise RuntimeError(f"unsupported platform: {platform}")


def is_platform_library(platform: str, dependency: str) -> bool:
    name = Path(dependency).name.lower()
    if platform == "macos-arm64":
        return dependency.startswith("/usr/lib/") or dependency.startswith(
            "/System/Library/"
        )
    if platform == "linux-x64":
        return name in LINUX_PLATFORM_LIBRARIES
    return (
        name in WINDOWS_PLATFORM_LIBRARIES
        or name.startswith("api-ms-win-")
        or name.startswith("ext-ms-win-")
    )


def verify_architecture(platform: str, library: Path) -> None:
    if platform == "macos-arm64":
        if output("lipo", "-archs", str(library)).strip() != "arm64":
            raise RuntimeError(f"{library.name}: not a single-architecture arm64 binary")
    elif platform == "linux-x64":
        header = output("readelf", "-h", str(library))
        if "Advanced Micro Devices X86-64" not in header:
            raise RuntimeError(f"{library.name}: not an x86-64 ELF binary")
    elif platform == "windows-x64":
        header = output("objdump", "-f", str(library))
        if "pei-x86-64" not in header:
            raise RuntimeError(f"{library.name}: not an x86-64 PE binary")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: audit-runtime.py PLATFORM CLASSIFIER_DIR")
    platform = sys.argv[1]
    directory = Path(sys.argv[2]).resolve()
    names = {
        line.strip()
        for line in (directory / "manifest.txt").read_text().splitlines()
        if line.strip()
    }
    normalized_names = {name.lower() for name in names}
    errors: list[str] = []

    for name in sorted(names):
        library = directory / name
        verify_architecture(platform, library)
        contents = library.read_bytes().lower()
        for marker in FORBIDDEN_CONTENT_MARKERS:
            if marker in contents:
                errors.append(
                    f"{name}: contains forbidden marker {marker.decode()}"
                )
        for dependency in dependencies(platform, library):
            dependency_name = Path(dependency).name.lower()
            if any(marker in dependency_name for marker in FORBIDDEN_LIBRARY_MARKERS):
                errors.append(f"{name}: imports forbidden library {dependency}")
                continue
            if dependency_name in normalized_names:
                continue
            if is_platform_library(platform, dependency):
                continue
            errors.append(f"{name}: unresolved non-platform import {dependency}")

    if errors:
        raise RuntimeError("runtime closure audit failed:\n" + "\n".join(errors))
    print(
        f"Audited {len(names)} {platform} libraries: complete staged closure; "
        "no Magick or sharp-libvips imports"
    )


if __name__ == "__main__":
    main()
