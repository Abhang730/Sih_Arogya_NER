"""Report the real structure of the downloaded dataset.

Written before any loader code, on purpose. Dataset layouts described in a paper
rarely match the archive you actually download, and guessing leads to a loader
that silently reads the wrong columns — which then trains a model on noise. This
script prints the truth so the loader can be written against it.

Run::

    python ml/common/inspect_dataset.py
"""

from __future__ import annotations

import collections
import pathlib
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent.parent
RAW_ZIP = ROOT / "ml" / "datasets" / "raw" / "clinical_gait_signals.zip"
EXTRACT_DIR = ROOT / "ml" / "datasets" / "raw" / "clinical_gait_signals"

MAX_ENTRIES_TO_LIST = 60


def extract_if_needed() -> None:
    if EXTRACT_DIR.exists() and any(EXTRACT_DIR.iterdir()):
        print(f"already extracted: {EXTRACT_DIR.relative_to(ROOT)}")
        return
    if not RAW_ZIP.exists():
        raise SystemExit(f"missing archive: {RAW_ZIP}")

    EXTRACT_DIR.mkdir(parents=True, exist_ok=True)
    print(f"extracting {RAW_ZIP.name} -> {EXTRACT_DIR.relative_to(ROOT)} ...")
    with zipfile.ZipFile(RAW_ZIP) as zf:
        members = zf.infolist()
        total = len(members)
        for index, member in enumerate(members, start=1):
            zf.extract(member, EXTRACT_DIR)
            if index % 500 == 0 or index == total:
                print(f"  {index}/{total} entries")
    print("extraction complete")


def name_shape(name: str) -> str:
    """Reduces a filename to its shape, so thousands of similar names collapse.

    'Patient_003_LeftFoot_1.csv' becomes 'Patient_###_LeftFoot_#.csv', which is
    what actually reveals the naming convention.
    """
    out: list[str] = []
    digits = False
    for ch in name:
        if ch.isdigit():
            if not digits:
                out.append("#")
                digits = True
        else:
            digits = False
            out.append(ch)
    return "".join(out)


def main() -> int:
    extract_if_needed()

    all_files = [p for p in EXTRACT_DIR.rglob("*") if p.is_file()]
    print(f"\nfiles: {len(all_files)}")
    if not all_files:
        return 1

    total_bytes = sum(p.stat().st_size for p in all_files)
    print(f"total size: {total_bytes / 1e9:.2f} GB")

    # ── file types ────────────────────────────────────────────────────────
    by_suffix = collections.Counter(p.suffix.lower() for p in all_files)
    print("\nextensions:")
    for suffix, count in by_suffix.most_common():
        print(f"  {suffix or '(none)':<12} {count}")

    # ── naming conventions per extension ──────────────────────────────────
    print("\nfilename shapes (top 25 per extension):")
    for suffix, _ in by_suffix.most_common(6):
        shapes = collections.Counter(
            name_shape(p.name) for p in all_files if p.suffix.lower() == suffix
        )
        print(f"  {suffix or '(none)'}:")
        for shape, count in shapes.most_common(25):
            print(f"    {count:>6}  {shape}")

    # ── directory layout ─────────────────────────────────────────────────
    print("\ntop-level entries under the extract root:")
    for child in sorted(EXTRACT_DIR.iterdir())[:MAX_ENTRIES_TO_LIST]:
        kind = "dir " if child.is_dir() else "file"
        print(f"  [{kind}] {child.name}")

    depths = collections.Counter(len(p.relative_to(EXTRACT_DIR).parts) for p in all_files)
    print("\npath depth distribution:")
    for depth, count in sorted(depths.items()):
        print(f"  depth {depth}: {count} files")

    # ── a worked example path ────────────────────────────────────────────
    sample = next(
        (p for p in sorted(all_files) if p.suffix.lower() in {".csv", ".txt", ".tsv"}),
        None,
    )
    if sample is not None:
        rel = sample.relative_to(EXTRACT_DIR)
        print(f"\nexample data file: {rel}")
        print(f"  path parts: {list(rel.parts)}")
        try:
            with sample.open("r", encoding="utf-8", errors="replace") as handle:
                for i, line in enumerate(handle):
                    if i >= 6:
                        break
                    print(f"  line {i}: {line.rstrip()[:200]}")
        except OSError as exc:
            print(f"  could not read: {exc}")

    # ── documentation files ──────────────────────────────────────────────
    doc_like = [
        p
        for p in all_files
        if p.suffix.lower() in {".md", ".txt", ".pdf", ".docx", ".xlsx", ".json"}
        or "readme" in p.name.lower()
    ]
    print(f"\ndocumentation / metadata candidates: {len(doc_like)}")
    for p in doc_like[:30]:
        print(f"  {p.relative_to(EXTRACT_DIR)}  ({p.stat().st_size} bytes)")

    return 0


if __name__ == "__main__":
    sys.exit(main())
