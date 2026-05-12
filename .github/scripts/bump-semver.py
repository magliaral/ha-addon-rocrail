#!/usr/bin/env python3
"""
Computes the next add-on SemVer based on Conventional Commits since a
given git revision range.

Mapping:
  - feat:           -> minor bump
  - feat(scope):    -> minor bump
  - fix:            -> patch bump
  - fix(scope):     -> patch bump
  - feat!:          -> major bump
  - feat(scope)!:   -> major bump
  - fix!:           -> major bump
  - fix(scope)!:    -> major bump
  - other types     -> no bump

We use ONLY the subject-line "!" marker for breaking changes - no
scanning of commit bodies for "BREAKING CHANGE:". Decision: the "!"
marker is unambiguous and easier to enforce.

When multiple commits exist in the range, the highest-priority bump
wins (major > minor > patch > none).

Output (GitHub-Actions $GITHUB_OUTPUT format on stdout):

    semver=X.Y.Z
    bumped=true|false
"""
from __future__ import annotations

import argparse
import re
import subprocess
import sys

CC_RE = re.compile(
    r"^(?P<type>feat|fix|chore|ci|docs|refactor|test|style|perf|build|revert)"
    r"(?:\([^)]*\))?(?P<bang>!?):"
)

# No '%' in the separator — git pretty-format treats '%%' as a literal
# '%', so a separator with '%' inside would round-trip differently
# between the format string and Python's split().
COMMIT_SEP = "<<<COMMIT-BOUNDARY>>>"


def classify(commit_subjects: list[str]) -> str:
    """Return one of 'major', 'minor', 'patch', 'none'."""
    bump = "none"
    for subject in commit_subjects:
        m = CC_RE.match(subject)
        if not m:
            continue
        ctype = m.group("type")
        is_breaking = m.group("bang") == "!"
        if is_breaking and ctype in ("feat", "fix"):
            return "major"
        if ctype == "feat" and bump in ("none", "patch"):
            bump = "minor"
        elif ctype == "fix" and bump == "none":
            bump = "patch"
    return bump


def collect_subjects(rev_range: str | None) -> list[str]:
    if not rev_range:
        return []
    result = subprocess.run(
        ["git", "log", rev_range, f"--pretty=format:{COMMIT_SEP}%n%s"],
        capture_output=True, text=True, check=True,
    )
    subjects = []
    for chunk in result.stdout.split(COMMIT_SEP):
        chunk = chunk.strip()
        if not chunk:
            continue
        for line in chunk.splitlines():
            if line.strip():
                subjects.append(line.strip())
                break
    return subjects


def bump_semver(current: str, level: str) -> str:
    parts = current.split(".")
    if len(parts) != 3 or not all(p.isdigit() for p in parts):
        raise ValueError(f"Not a clean SemVer: {current!r}")
    major, minor, patch = (int(p) for p in parts)
    if level == "major":
        return f"{major + 1}.0.0"
    if level == "minor":
        return f"{major}.{minor + 1}.0"
    if level == "patch":
        return f"{major}.{minor}.{patch + 1}"
    return current


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--base-semver", required=True,
                   help="Current SemVer (e.g. 0.3.2) used as the bump base.")
    p.add_argument("--range", default=None,
                   help="git revision range (e.g. 'v0.3.2..HEAD'). "
                        "Omit on first run when no v* tag exists yet.")
    args = p.parse_args()

    subjects = collect_subjects(args.range)
    level = classify(subjects)
    new_semver = bump_semver(args.base_semver, level)
    bumped = new_semver != args.base_semver

    sys.stderr.write(f"Considered {len(subjects)} commit(s); bump level: {level}\n")
    for s in subjects:
        sys.stderr.write(f"  - {s}\n")
    sys.stderr.write(f"Base SemVer: {args.base_semver} -> {new_semver}\n")

    print(f"semver={new_semver}")
    print(f"bumped={'true' if bumped else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
