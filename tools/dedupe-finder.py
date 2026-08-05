#!/usr/bin/env python3
r"""dedupe-finder.py — Find duplicate files by content, not by name.

Cross-platform (Windows 10/11, and Debian-flavored Linux — Ubuntu, Mint):
uses only the Python standard library, so there is nothing to install
beyond Python itself.

How it decides two files are duplicates
----------------------------------------
Filenames and extensions are never used to decide duplicates — only file
content is. Two files with unrelated names and identical bytes are always
reported as duplicates; two files with the same name but different bytes
never are. To avoid hashing every byte of every file, matches are narrowed
in three cheap-to-expensive stages before any file is fully hashed:

  1. Group by file size.       A size with only one file can't have a
                                duplicate — dropped for free, no I/O.
  2. Partial hash (first 64 KB) of what's left in each size group, to
     split away files that just happen to share a size.
  3. Full streaming hash (SHA-256, read in 1 MB chunks) of what's left
     in each partial-hash group — this is the final, authoritative check.

Usage
-----
Linux/Debian/Ubuntu/Mint:
    python3 dedupe-finder.py /path/to/photos /path/to/music
    python3 dedupe-finder.py ~/Pictures --category photos music --json report.json

Windows 10/11 (PowerShell or cmd, Python from python.org or the Store):
    python dedupe-finder.py D:\Photos E:\Music
    py dedupe-finder.py "C:\Users\me\Documents" --category docs

Report only (default — never touches your files):
    python3 dedupe-finder.py /data

Delete duplicates, keeping the oldest copy of each set (dry run first,
then actually do it with --yes):
    python3 dedupe-finder.py /data --delete --keep oldest
    python3 dedupe-finder.py /data --delete --keep oldest --yes

Move duplicates out of the way instead of deleting:
    python3 dedupe-finder.py /data --move-to /data/_duplicates --yes

Save space in place by replacing duplicates with hardlinks to the kept
copy (same volume only; Windows needs an NTFS volume and typically an
elevated/admin shell):
    python3 dedupe-finder.py /data --hardlink --yes
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import sys
from pathlib import Path
from collections import defaultdict
from datetime import datetime

PARTIAL_HASH_BYTES = 64 * 1024
CHUNK_SIZE = 1024 * 1024

EXTENSION_CATEGORIES = {
    "photos": {
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".tif", ".tiff", ".heic",
        ".heif", ".webp", ".raw", ".cr2", ".cr3", ".nef", ".arw", ".dng",
        ".orf", ".rw2", ".svg", ".ico", ".psd",
    },
    "music": {
        ".mp3", ".flac", ".wav", ".aac", ".m4a", ".ogg", ".opus", ".wma",
        ".alac", ".aiff", ".ape", ".mid", ".midi",
    },
    "video": {
        ".mp4", ".mkv", ".avi", ".mov", ".wmv", ".flv", ".webm", ".m4v",
        ".mpg", ".mpeg", ".3gp", ".ts",
    },
    "docs": {
        ".doc", ".docx", ".odt", ".rtf", ".txt", ".pdf", ".xls", ".xlsx",
        ".ods", ".csv", ".ppt", ".pptx", ".odp", ".md", ".epub", ".mobi",
        ".pages", ".numbers", ".key",
    },
}

DEFAULT_EXCLUDE_DIRS = {
    ".git", ".svn", "node_modules", "__pycache__",
    "$RECYCLE.BIN", "System Volume Information",
    ".Trash-1000", ".Trashes",
}


def parse_args(argv):
    p = argparse.ArgumentParser(
        description="Find duplicate files by content hash (not filename).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    p.add_argument("paths", nargs="+", type=Path, help="Directories to scan (recursive).")
    p.add_argument(
        "--category", nargs="+", choices=sorted(EXTENSION_CATEGORIES), default=None,
        help="Limit to one or more built-in categories (photos, music, video, docs). "
             "Default: all files.",
    )
    p.add_argument(
        "--ext", nargs="+", default=None,
        help="Limit to specific extensions instead of/in addition to --category, e.g. --ext .heic .dng",
    )
    p.add_argument("--min-size", type=int, default=1, help="Skip files smaller than this many bytes (default: 1).")
    p.add_argument("--follow-symlinks", action="store_true", help="Follow symlinked directories (off by default to avoid loops/double-counting).")
    p.add_argument("--exclude-dir", nargs="+", default=[], help="Additional directory names to skip, beyond the built-in defaults.")

    p.add_argument("--json", type=Path, metavar="FILE", help="Also write the report as JSON.")
    p.add_argument("--csv", type=Path, metavar="FILE", help="Also write the report as CSV.")
    p.add_argument("--quiet", action="store_true", help="Suppress the per-set text report (still writes --json/--csv if given).")

    action = p.add_mutually_exclusive_group()
    action.add_argument("--delete", action="store_true", help="Delete all but one file per duplicate set.")
    action.add_argument("--move-to", type=Path, metavar="DIR", help="Move all but one file per duplicate set into DIR (mirroring their relative paths).")
    action.add_argument("--hardlink", action="store_true", help="Replace duplicates with hardlinks to the kept copy (same volume only).")

    p.add_argument(
        "--keep", choices=["first", "oldest", "newest", "shortest-path"], default="first",
        help="Which file in each duplicate set to keep when using --delete/--move-to/--hardlink (default: first found).",
    )
    p.add_argument("--yes", action="store_true", help="Actually perform --delete/--move-to/--hardlink. Without this, they run as a dry run and only print what would happen.")

    return p.parse_args(argv)


def resolve_allowed_extensions(args):
    exts = set()
    if args.category:
        for cat in args.category:
            exts |= EXTENSION_CATEGORIES[cat]
    if args.ext:
        exts |= {e if e.startswith(".") else f".{e}" for e in (x.lower() for x in args.ext)}
    return exts or None  # None means "all extensions"


def iter_candidate_files(paths, allowed_extensions, min_size, follow_symlinks, exclude_dirs):
    seen_ids = set()  # (dev, inode) or resolved path, to avoid double-counting overlapping/symlinked trees
    for root_path in paths:
        if not root_path.exists():
            print(f"[WARN] Path does not exist, skipping: {root_path}", file=sys.stderr)
            continue
        for dirpath, dirnames, filenames in os.walk(root_path, followlinks=follow_symlinks):
            dirnames[:] = [d for d in dirnames if d not in exclude_dirs]
            for name in filenames:
                fpath = Path(dirpath) / name
                if allowed_extensions is not None and fpath.suffix.lower() not in allowed_extensions:
                    continue
                try:
                    st = fpath.stat()
                except OSError as e:
                    print(f"[WARN] Can't stat {fpath}: {e}", file=sys.stderr)
                    continue
                if st.st_size < min_size:
                    continue
                key = (st.st_dev, st.st_ino) if hasattr(st, "st_ino") and st.st_ino else str(fpath.resolve())
                if key in seen_ids:
                    continue
                seen_ids.add(key)
                yield fpath, st.st_size, st.st_mtime


def partial_hash(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        h.update(f.read(PARTIAL_HASH_BYTES))
    return h.hexdigest()


def full_hash(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            chunk = f.read(CHUNK_SIZE)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def find_duplicates(paths, allowed_extensions, min_size, follow_symlinks, exclude_dirs):
    by_size = defaultdict(list)
    total_scanned = 0
    for fpath, size, mtime in iter_candidate_files(paths, allowed_extensions, min_size, follow_symlinks, exclude_dirs):
        by_size[size].append((fpath, mtime))
        total_scanned += 1

    size_groups = [group for group in by_size.values() if len(group) > 1]

    by_partial = defaultdict(list)
    for group in size_groups:
        for fpath, mtime in group:
            try:
                ph = partial_hash(fpath)
            except OSError as e:
                print(f"[WARN] Can't read {fpath}: {e}", file=sys.stderr)
                continue
            by_partial[(fpath.stat().st_size, ph)].append((fpath, mtime))

    partial_groups = [group for group in by_partial.values() if len(group) > 1]

    by_full = defaultdict(list)
    for group in partial_groups:
        for fpath, mtime in group:
            try:
                fh = full_hash(fpath)
            except OSError as e:
                print(f"[WARN] Can't read {fpath}: {e}", file=sys.stderr)
                continue
            by_full[fh].append((fpath, mtime))

    duplicate_sets = {h: group for h, group in by_full.items() if len(group) > 1}
    return duplicate_sets, total_scanned


def choose_keeper(group, strategy):
    if strategy == "oldest":
        return min(group, key=lambda item: item[1])
    if strategy == "newest":
        return max(group, key=lambda item: item[1])
    if strategy == "shortest-path":
        return min(group, key=lambda item: len(str(item[0])))
    return group[0]  # "first"


def print_report(duplicate_sets, total_scanned):
    total_dupe_files = sum(len(g) - 1 for g in duplicate_sets.values())
    reclaimable = sum((len(g) - 1) * g[0][0].stat().st_size for g in duplicate_sets.values())

    if not duplicate_sets:
        print(f"Scanned {total_scanned} files. No duplicates found.")
        return

    for i, (h, group) in enumerate(sorted(duplicate_sets.items()), 1):
        size = group[0][0].stat().st_size
        print(f"\nSet {i}  ({len(group)} files, {size:,} bytes each, sha256 {h[:12]}...)")
        for fpath, _mtime in group:
            print(f"  {fpath}")

    print(
        f"\nScanned {total_scanned} files. "
        f"{len(duplicate_sets)} duplicate sets, {total_dupe_files} redundant copies, "
        f"{reclaimable:,} bytes reclaimable."
    )


def write_json(path: Path, duplicate_sets):
    data = []
    for h, group in duplicate_sets.items():
        size = group[0][0].stat().st_size
        data.append({
            "sha256": h,
            "size_bytes": size,
            "files": [str(fpath) for fpath, _ in group],
        })
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(f"JSON report written to {path}")


def write_csv(path: Path, duplicate_sets):
    with open(path, "w", newline="", encoding="utf-8") as f:
        writer = csv.writer(f)
        writer.writerow(["sha256", "size_bytes", "path"])
        for h, group in duplicate_sets.items():
            size = group[0][0].stat().st_size
            for fpath, _ in group:
                writer.writerow([h, size, str(fpath)])
    print(f"CSV report written to {path}")


def apply_action(args, duplicate_sets):
    if not (args.delete or args.move_to or args.hardlink):
        return

    dry_run = not args.yes
    label = "[DRY RUN] Would " if dry_run else ""

    for group in duplicate_sets.values():
        keeper, _ = choose_keeper(group, args.keep)
        for fpath, _mtime in group:
            if fpath == keeper:
                continue
            if args.delete:
                print(f"{label}delete {fpath}")
                if not dry_run:
                    try:
                        fpath.unlink()
                    except OSError as e:
                        print(f"[WARN] Failed to delete {fpath}: {e}", file=sys.stderr)
            elif args.move_to:
                dest = args.move_to / fpath.name
                dest_dir = dest.parent
                print(f"{label}move {fpath} -> {dest}")
                if not dry_run:
                    try:
                        dest_dir.mkdir(parents=True, exist_ok=True)
                        if dest.exists():
                            dest = dest_dir / f"{fpath.stem}_{fpath.parent.name}{fpath.suffix}"
                        fpath.rename(dest)
                    except OSError as e:
                        print(f"[WARN] Failed to move {fpath}: {e}", file=sys.stderr)
            elif args.hardlink:
                print(f"{label}replace {fpath} with a hardlink to {keeper}")
                if not dry_run:
                    try:
                        tmp = fpath.with_name(fpath.name + ".dedupe-tmp")
                        os.link(keeper, tmp)
                        os.replace(tmp, fpath)
                    except OSError as e:
                        print(f"[WARN] Failed to hardlink {fpath}: {e}", file=sys.stderr)

    if dry_run and (args.delete or args.move_to or args.hardlink):
        print("\nThis was a dry run — nothing was changed. Re-run with --yes to apply.")


def main(argv=None):
    args = parse_args(argv if argv is not None else sys.argv[1:])
    allowed_extensions = resolve_allowed_extensions(args)
    exclude_dirs = DEFAULT_EXCLUDE_DIRS | set(args.exclude_dir)

    started = datetime.now()
    duplicate_sets, total_scanned = find_duplicates(
        args.paths, allowed_extensions, args.min_size, args.follow_symlinks, exclude_dirs,
    )
    elapsed = (datetime.now() - started).total_seconds()

    if not args.quiet:
        print_report(duplicate_sets, total_scanned)
        print(f"Done in {elapsed:.1f}s.")

    if args.json:
        write_json(args.json, duplicate_sets)
    if args.csv:
        write_csv(args.csv, duplicate_sets)

    apply_action(args, duplicate_sets)
    return 0


if __name__ == "__main__":
    sys.exit(main())
