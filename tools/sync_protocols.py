#!/usr/bin/env python3
"""Copy the canonical protocols/ tree into the Flutter asset bundle.

Why a copy at all
-----------------
The protocol definitions are the single source of truth for both the mobile app
and the backend, so they live at the repository root rather than inside any one
consumer. Flutter can only bundle assets that sit inside the package directory,
so the protocol tree is mirrored into mobile/assets/protocols/.

The mirror is committed (so a fresh clone builds with no extra steps) and a
Dart test asserts the mirror is byte-identical to the source. That gives us
both: zero setup friction, and drift caught by `flutter test` rather than by a
runtime surprise in the field.

Run this after editing anything under protocols/:

    python tools/sync_protocols.py
"""

from __future__ import annotations

import filecmp
import shutil
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "protocols"
TARGET = ROOT / "mobile" / "assets" / "protocols"

# The schema is bundled too: the app validates what it loads, so a malformed or
# hand-edited protocol on a provisioned device is caught before it reaches a
# screening screen.
INCLUDE_DIRS = ["core", "schema"]


def iter_sources() -> list[Path]:
    files: list[Path] = [SOURCE / "index.json"]
    for name in INCLUDE_DIRS:
        files.extend(sorted((SOURCE / name).rglob("*.json")))
    files.extend(sorted(SOURCE.glob("*/protocol.json")))
    return [f for f in files if f.is_file()]


def main() -> int:
    if not SOURCE.is_dir():
        print(f"ERROR: {SOURCE} does not exist")
        return 1

    TARGET.mkdir(parents=True, exist_ok=True)

    copied = 0
    unchanged = 0
    for src in iter_sources():
        rel = src.relative_to(SOURCE)
        dst = TARGET / rel
        dst.parent.mkdir(parents=True, exist_ok=True)
        if dst.exists() and filecmp.cmp(src, dst, shallow=False):
            unchanged += 1
            continue
        shutil.copy2(src, dst)
        print(f"  copy  {rel}")
        copied += 1

    # remove stale files in the mirror that no longer exist at the source
    removed = 0
    for dst in sorted(TARGET.rglob("*.json")):
        rel = dst.relative_to(TARGET)
        if not (SOURCE / rel).exists():
            dst.unlink()
            print(f"  rm    {rel}")
            removed += 1

    print()
    print(f"source      : {SOURCE.relative_to(ROOT)}")
    print(f"target      : {TARGET.relative_to(ROOT)}")
    print(f"copied      : {copied}")
    print(f"unchanged   : {unchanged}")
    print(f"removed     : {removed}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
