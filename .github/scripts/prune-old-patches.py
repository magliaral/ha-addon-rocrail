#!/usr/bin/env python3
"""
Prune obsolete tags after a CC-driven minor or major release.

Runs in the finalize job after a new vX.Y.0 tag has been planted.
For every existing v-tag of the form vA.B.C with (A, B) < (X, Y),
the script groups candidates by their (A, B) minor series and keeps
only the **highest tag** in each series as a single endpoint anchor.
All other tags in the same series are removed:

  - GitHub Release object + remote git tag  (via `gh release delete
    --yes --cleanup-tag`); if no release exists for the tag,
    fall back to plain `git push --delete origin` for the ref
  - Local git tag                            (`git tag -d`)
  - GHCR image tag X.Y.C in both amd64-addon-rocrail and
    aarch64-addon-rocrail packages

The X.Y.0 minor/major anchor is NOT exempt: if a higher patch
exists in the same series (e.g. v1.2.0 alongside v1.2.2), the
anchor is treated like any other obsolete tag and pruned in favour
of the highest patch. A series with only one tag (typically X.Y.0
alone) keeps that tag — it is its own series endpoint.

Tags in the current minor series (A == X and B == Y) are out of
scope by the `(A, B) < (X, Y)` filter.

Dry-run mode prints the plan without modifying anything.

Calls:
  python3 prune-old-patches.py \\
      --new-version 1.6.0 \\
      --owner magliaral \\
      --package-amd64 amd64-addon-rocrail \\
      --package-aarch64 aarch64-addon-rocrail \\
      [--dry-run]

Authentication: GH_TOKEN environment variable (set by the workflow
from secrets.GITHUB_TOKEN).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from typing import Iterable

SEMVER_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
GITHUB_API = "https://api.github.com"


def log(msg: str) -> None:
    print(msg, flush=True)


def notice(msg: str) -> None:
    print(f"::notice::{msg}", flush=True)


def warning(msg: str) -> None:
    print(f"::warning::{msg}", flush=True)


def run(cmd: list[str], check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=check)


def list_local_tags() -> list[tuple[int, int, int, str]]:
    result = run(["git", "tag", "--list", "v*"])
    tags: list[tuple[int, int, int, str]] = []
    for line in result.stdout.splitlines():
        line = line.strip()
        m = SEMVER_RE.match(line)
        if m:
            tags.append((int(m.group(1)), int(m.group(2)), int(m.group(3)), line))
    return tags


def release_exists(tag: str) -> bool:
    # gh release view exits non-zero if the release does not exist.
    result = run(["gh", "release", "view", tag], check=False)
    return result.returncode == 0


def gh_api(method: str, path: str, token: str) -> dict | list | None:
    req = urllib.request.Request(
        f"{GITHUB_API}{path}",
        method=method,
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "ha-addon-rocrail-prune/1.0",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            if resp.status == 204:
                return None
            data = resp.read().decode("utf-8", errors="replace")
            return json.loads(data) if data else None
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
        warning(f"HTTP {exc.code} {method} {path}: {body[:300]}")
        raise


def list_package_versions(owner: str, package: str, token: str) -> list[dict]:
    # GHCR is org-owned for org repos and user-owned for user repos.
    # For magliaral/* (user repo) the /users/ endpoint is correct.
    versions: list[dict] = []
    page = 1
    while True:
        path = (
            f"/users/{owner}/packages/container/{package}/versions"
            f"?per_page=100&page={page}"
        )
        chunk = gh_api("GET", path, token)
        if not chunk:
            break
        assert isinstance(chunk, list)
        versions.extend(chunk)
        if len(chunk) < 100:
            break
        page += 1
    return versions


def find_version_id_by_tag(versions: list[dict], image_tag: str) -> int | None:
    for v in versions:
        meta = v.get("metadata") or {}
        container = meta.get("container") or {}
        tags = container.get("tags") or []
        if image_tag in tags:
            return int(v["id"])
    return None


def delete_package_version(owner: str, package: str, version_id: int, token: str) -> None:
    gh_api("DELETE", f"/users/{owner}/packages/container/{package}/versions/{version_id}", token)


def delete_release_and_tag(tag: str) -> None:
    # Primary path: `gh release delete --yes --cleanup-tag` removes
    # both the Release object and the matching remote git ref in one
    # API round-trip. Fallback to plain `git push --delete` if no
    # Release object exists for the tag (pre-f008dcd vintage). Local
    # `git tag -d` runs after either path for idempotency.
    if release_exists(tag):
        result = run(["gh", "release", "delete", tag, "--yes", "--cleanup-tag"], check=False)
        if result.returncode != 0:
            warning(f"gh release delete {tag} failed: {result.stderr.strip()}")
    else:
        result = run(["git", "push", "--delete", "origin", tag], check=False)
        if result.returncode != 0:
            warning(f"git push --delete origin {tag} failed: {result.stderr.strip()}")
    result = run(["git", "tag", "-d", tag], check=False)
    if result.returncode != 0:
        warning(f"git tag -d {tag} failed: {result.stderr.strip()}")


def main(argv: Iterable[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--new-version", required=True, help="The version just released, e.g. 1.5.0")
    ap.add_argument("--owner", required=True, help="GHCR/GitHub owner, e.g. magliaral")
    ap.add_argument("--package-amd64", required=True)
    ap.add_argument("--package-aarch64", required=True)
    ap.add_argument("--dry-run", action="store_true")
    args = ap.parse_args(list(argv))

    m = re.match(r"^(\d+)\.(\d+)\.(\d+)$", args.new_version)
    if not m:
        log(f"--new-version must be X.Y.Z; got '{args.new_version}'")
        return 2
    new_major, new_minor, new_patch = (int(x) for x in m.groups())

    if new_patch != 0:
        notice(f"new-version {args.new_version} is a patch bump; nothing to prune.")
        return 0

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token and not args.dry_run:
        log("GH_TOKEN (or GITHUB_TOKEN) not set; cannot delete GHCR versions.")
        return 2

    tags = list_local_tags()
    # Candidate tags: every v-tag of an older minor series (any patch
    # number, including X.Y.0). Per series the highest tag wins as
    # endpoint anchor; everything else in the series is pruned. The
    # current minor series is excluded by (major, minor) < new.
    candidates = [
        (major, minor, patch, name)
        for (major, minor, patch, name) in tags
        if (major, minor) < (new_major, new_minor)
    ]
    candidates.sort()

    if not candidates:
        notice("no candidate tags of older minor series found.")
        return 0

    log(f"Candidate tags (older minor series): {[c[3] for c in candidates]}")

    versions_amd64: list[dict] = []
    versions_aarch64: list[dict] = []
    if not args.dry_run:
        versions_amd64 = list_package_versions(args.owner, args.package_amd64, token)
        versions_aarch64 = list_package_versions(args.owner, args.package_aarch64, token)
        log(f"GHCR {args.package_amd64}: {len(versions_amd64)} versions")
        log(f"GHCR {args.package_aarch64}: {len(versions_aarch64)} versions")

    # Group candidates by (major, minor); per group keep the highest
    # patch as the series endpoint anchor, delete the rest.
    groups: dict[tuple[int, int], list[tuple[int, str]]] = defaultdict(list)
    for major, minor, patch, tag in candidates:
        groups[(major, minor)].append((patch, tag))

    plan_delete: list[str] = []
    plan_keep: list[str] = []
    for (major, minor), patches in sorted(groups.items()):
        patches.sort()  # ascending by patch
        keep_patch, keep_tag = patches[-1]
        plan_keep.append(f"{keep_tag} (highest tag in {major}.{minor}.x - series endpoint)")
        for _, tag in patches[:-1]:
            plan_delete.append(tag)

    log("")
    log("== Plan ==")
    for entry in plan_keep:
        log(f"  keep   {entry}")
    for tag in plan_delete:
        log(f"  delete {tag}")
    log("")

    if args.dry_run:
        notice(f"--dry-run; would delete {len(plan_delete)} tag(s).")
        return 0

    deleted = 0
    for tag in plan_delete:
        image_tag = tag.lstrip("v")  # GHCR image tag is "1.2.1", not "v1.2.1"

        # amd64 package
        vid = find_version_id_by_tag(versions_amd64, image_tag)
        if vid is not None:
            try:
                delete_package_version(args.owner, args.package_amd64, vid, token)
                notice(f"deleted GHCR {args.package_amd64}:{image_tag} (version_id={vid})")
            except urllib.error.HTTPError as exc:
                warning(f"GHCR delete failed for {args.package_amd64}:{image_tag}: HTTP {exc.code}")
        else:
            log(f"  (no GHCR version found for {args.package_amd64}:{image_tag})")

        # aarch64 package
        vid = find_version_id_by_tag(versions_aarch64, image_tag)
        if vid is not None:
            try:
                delete_package_version(args.owner, args.package_aarch64, vid, token)
                notice(f"deleted GHCR {args.package_aarch64}:{image_tag} (version_id={vid})")
            except urllib.error.HTTPError as exc:
                warning(f"GHCR delete failed for {args.package_aarch64}:{image_tag}: HTTP {exc.code}")
        else:
            log(f"  (no GHCR version found for {args.package_aarch64}:{image_tag})")

        delete_release_and_tag(tag)
        notice(f"deleted git tag {tag} (and release object if present)")
        deleted += 1

    notice(f"pruned {deleted} stale patch tag(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
