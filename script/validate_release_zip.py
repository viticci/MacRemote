#!/usr/bin/env python3
"""Validate untrusted ZIP central-directory metadata before extraction."""

from __future__ import annotations

import argparse
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path


MAX_ENTRY_COUNT = 4096
MAX_EXPANDED_SIZE = 1024 * 1024 * 1024


def fail(message: str) -> None:
    raise ValueError(message)


def canonical_name(name: str) -> str:
    return unicodedata.normalize("NFC", name).casefold().rstrip("/")


def validate(path: Path) -> list[str]:
    try:
        archive = zipfile.ZipFile(path)
    except (OSError, zipfile.BadZipFile) as error:
        fail(f"could not read the zip directory: {error}")

    with archive:
        entries = archive.infolist()
        if not entries:
            fail("zip is empty")
        if len(entries) > MAX_ENTRY_COUNT:
            fail(f"zip contains too many entries (maximum {MAX_ENTRY_COUNT})")

        expanded_size = 0
        exact_names: set[str] = set()
        canonical_names: dict[str, str] = {}
        result: list[str] = []

        for entry in entries:
            name = entry.filename
            if not name:
                fail("zip contains an empty archive entry")
            if name in exact_names:
                fail(f"zip contains a duplicate archive entry: {name}")
            exact_names.add(name)

            canonical = canonical_name(name)
            previous = canonical_names.get(canonical)
            if previous is not None and previous != name:
                fail(f"zip contains colliding archive names: {previous} and {name}")
            canonical_names[canonical] = name

            if name.startswith("/") or "\\" in name or "//" in name:
                fail(f"zip contains an unsafe archive path: {name}")
            components = name.rstrip("/").split("/")
            if any(component in {"", ".", ".."} for component in components):
                fail(f"zip contains an unsafe archive path: {name}")
            if entry.flag_bits & 0x1:
                fail(f"zip contains an encrypted archive entry: {name}")

            unix_mode = (entry.external_attr >> 16) & 0xFFFF
            file_type = stat.S_IFMT(unix_mode)
            if entry.create_system == 3 and file_type == stat.S_IFLNK:
                fail(f"zip contains a symbolic link entry: {name}")
            if entry.create_system == 3 and file_type not in {0, stat.S_IFREG, stat.S_IFDIR}:
                fail(f"zip contains an unsupported special entry: {name}")

            expanded_size += entry.file_size
            if expanded_size > MAX_EXPANDED_SIZE:
                fail(
                    "zip declares too much expanded data "
                    f"(maximum {MAX_EXPANDED_SIZE} bytes)"
                )
            result.append(name)

    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("archive", type=Path)
    args = parser.parse_args()
    try:
        entries = validate(args.archive)
    except ValueError as error:
        print(f"release verification failed: {error}", file=sys.stderr)
        return 1
    for entry in entries:
        print(entry)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
