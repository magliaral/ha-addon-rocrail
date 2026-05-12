#!/usr/bin/env python3
"""
Prepends a release section to rocrail/CHANGELOG.md after the
top-level "# Changelog" header.

Format produced (wrapper-release model — no Rocrail-rev bullets):

    ## Version <version> - (DD.MM.YYYY)

    > <commit subject 1>
    > <commit subject 2>
    > ...

The blockquote carries the Conventional-Commit subjects gathered
between the previous v-tag and HEAD. If the list is empty we emit a
"Wrapper maintenance release" placeholder so every section has the
same shape.

Idempotent: if a section with the same "## Version <version> - " prefix
already exists, the script logs "already present" and exits 0 without
writing.

If the file is missing the leading "# Changelog" header, the script
exits non-zero rather than guessing where to insert.

Per-arch Rocrail revisions used to be tracked here in the pre-2.0.0
GHCR-image model. They're now tracked at runtime per HA installation
in /data/rocrail/.installed-revision and surfaced in the add-on log
banner, not in this CHANGELOG.
"""
from __future__ import annotations

import argparse
import re
import sys
from datetime import date, datetime
from pathlib import Path

# Subjects of release commits themselves are filtered out: they describe
# the act of releasing, not the changes that prompted it.
RELEASE_SUBJECT_RE = re.compile(r"^chore: release\b", re.IGNORECASE)
EMPTY_PLACEHOLDER = "Wrapper maintenance release"


def load_subjects(path: Path | None) -> list[str]:
    if path is None:
        return []
    if not path.exists():
        return []
    raw = path.read_text(encoding="utf-8").splitlines()
    subjects = []
    for line in raw:
        s = line.strip()
        if not s:
            continue
        if RELEASE_SUBJECT_RE.match(s):
            continue
        subjects.append(s)
    return subjects


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--changelog", required=True, type=Path,
                   help="Path to CHANGELOG.md")
    p.add_argument("--version", required=True,
                   help="Version string, e.g. 2.0.0")
    p.add_argument("--date", default=date.today().isoformat(),
                   help="Release date in ISO format (default: today)")
    p.add_argument("--commit-subjects-file", type=Path, default=None,
                   help="Optional file with one commit subject per line "
                        "(empty file or omitted -> placeholder)")
    args = p.parse_args()

    if not args.changelog.exists():
        sys.stderr.write(f"::error::CHANGELOG not found: {args.changelog}\n")
        return 1

    text = args.changelog.read_text(encoding="utf-8")

    heading_prefix = f"## Version {args.version} - "
    if re.search(rf"^{re.escape(heading_prefix)}", text, re.MULTILINE):
        sys.stderr.write(f"Section for {args.version} already present, skipping prepend\n")
        return 0

    # ISO YYYY-MM-DD -> Swiss DD.MM.YYYY for the heading.
    pretty_date = datetime.strptime(args.date, "%Y-%m-%d").strftime("%d.%m.%Y")

    subjects = load_subjects(args.commit_subjects_file)
    if not subjects:
        subjects = [EMPTY_PLACEHOLDER]
    quote_lines = "".join(f"> {s}\n" for s in subjects)

    block = (
        f"## Version {args.version} - ({pretty_date})\n"
        f"\n"
        f"{quote_lines}"
        f"\n"
    )

    lines = text.splitlines(keepends=True)
    insert_at = None
    for i, line in enumerate(lines):
        if line.startswith("# Changelog"):
            insert_at = i + 1
            break

    if insert_at is None:
        sys.stderr.write("::error::CHANGELOG.md missing '# Changelog' top-level header\n")
        return 1

    if insert_at < len(lines) and lines[insert_at].strip() == "":
        insert_at += 1

    new_lines = lines[:insert_at] + [block] + lines[insert_at:]
    args.changelog.write_text("".join(new_lines), encoding="utf-8")
    sys.stderr.write(f"Prepended section {args.version} to {args.changelog}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
