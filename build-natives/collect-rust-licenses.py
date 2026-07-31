#!/usr/bin/env python3
"""Collect license metadata and texts for Rust crates linked into librsvg."""

from __future__ import annotations

import json
from pathlib import Path
import shutil
import subprocess
import sys


LICENSE_NAMES = ("LICENSE*", "LICENCE*", "COPYING*", "COPYRIGHT*", "NOTICE*")


def safe_name(value: str) -> str:
    return "".join(character if character.isalnum() or character in ".-_" else "_"
                   for character in value)


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: collect-rust-licenses.py LIBRSVG_SOURCE DEST")

    source = Path(sys.argv[1]).resolve()
    destination = Path(sys.argv[2]).resolve()
    metadata = json.loads(
        subprocess.run(
            [
                "cargo",
                "metadata",
                "--format-version",
                "1",
                "--locked",
                "--manifest-path",
                str(source / "Cargo.toml"),
            ],
            check=True,
            encoding="utf-8",
            text=True,
            stdout=subprocess.PIPE,
        ).stdout
    )

    packages = {package["id"]: package for package in metadata["packages"]}
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    roots = [
        package["id"]
        for package in metadata["packages"]
        if package["name"] in {"librsvg", "librsvg-c"}
        and Path(package["manifest_path"]).is_relative_to(source)
    ]
    if not roots:
        raise RuntimeError("cargo metadata did not contain the librsvg packages")

    reachable: set[str] = set()
    pending = roots[:]
    while pending:
        package_id = pending.pop()
        if package_id in reachable:
            continue
        reachable.add(package_id)
        for dependency in nodes[package_id]["deps"]:
            # Test-only dependencies are not linked into the shipped library.
            if all(kind["kind"] == "dev" for kind in dependency["dep_kinds"]):
                continue
            pending.append(dependency["pkg"])

    destination.mkdir(parents=True, exist_ok=True)
    inventory = ["name\tversion\tlicense\tsource\trepository\tauthors\n"]
    missing_text: list[str] = []
    for package_id in sorted(reachable, key=lambda value: (
        packages[value]["name"], packages[value]["version"]
    )):
        package = packages[package_id]
        if package["source"] is None:
            continue
        package_dir = Path(package["manifest_path"]).parent
        component = destination / safe_name(
            f'{package["name"]}-{package["version"]}'
        )
        inventory.append(
            "\t".join(
                (
                    package["name"],
                    package["version"],
                    package["license"] or "unspecified",
                    package["source"],
                    package["repository"] or "",
                    "; ".join(package["authors"]),
                )
            )
            + "\n"
        )
        candidates: set[Path] = set()
        if package["license_file"]:
            candidates.add(Path(package["license_file"]))
        for pattern in LICENSE_NAMES:
            candidates.update(
                path for path in package_dir.glob(pattern) if path.is_file()
            )
        if not candidates:
            if not package["license"]:
                raise RuntimeError(
                    f'{package["name"]} {package["version"]} has neither '
                    "license metadata nor a distributable license file"
                )
            missing_text.append(
                f'{package["name"]} {package["version"]} '
                f'({package["license"] or "unspecified"})'
            )
            continue
        component.mkdir(parents=True, exist_ok=True)
        for license_path in sorted(candidates):
            shutil.copy2(license_path, component / license_path.name)

    if missing_text:
        (destination / "PACKAGES-WITHOUT-LICENSE-FILE.txt").write_text(
            "These crates declare the following SPDX licenses in their "
            "published metadata but do not include a separate license file "
            "in the crate archive. Their identities, repositories, authors, "
            "and license expressions are also recorded in "
            "RUST-COMPONENTS.tsv. Canonical texts for each declared license "
            "occur in the other component directories.\n\n"
            + "\n".join(missing_text)
            + "\n",
            encoding="utf-8",
            newline="\n",
        )
    (destination / "RUST-COMPONENTS.tsv").write_text(
        "".join(inventory), encoding="utf-8", newline="\n"
    )


if __name__ == "__main__":
    main()
