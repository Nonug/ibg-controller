#!/usr/bin/env python3
"""Bump the pinned gnzsnz/ib-gateway base to a moving tag's current digest.

Keeps the base digest-pinned (reproducibility) while automating the bump.
By default tracks `stable`; pass --tag to track another channel. Rewrites
`ARG UPSTREAM_IMAGE` / `ARG IB_GATEWAY_VERSION` in the Dockerfile and the
"Release images pin **X**" line in README.md.

    scripts/bump_upstream_base.py [--tag stable] [--check]

Without --check the files are rewritten in place and the exit status is 0.
With --check nothing is written: exit 0 if already current, 1 if a bump is
available, so a caller can gate on it.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.request
from typing import Any

REGISTRY = "ghcr.io"
REPO = "gnzsnz/ib-gateway"
USER_AGENT = "ibg-controller-bump/1.0"
ACCEPT = ", ".join(
    [
        "application/vnd.oci.image.index.v1+json",
        "application/vnd.docker.distribution.manifest.list.v2+json",
        "application/vnd.oci.image.manifest.v1+json",
        "application/vnd.docker.distribution.manifest.v2+json",
    ]
)
UPSTREAM_RE = re.compile(r"^ARG UPSTREAM_IMAGE=(?P<ref>.+)$", re.MULTILINE)
VERSION_RE = re.compile(r"^ARG IB_GATEWAY_VERSION=.*$", re.MULTILINE)
README_RE = re.compile(r"(Release images pin \*\*)[^*]+(\*\*)")


def _request(url: str, accept: str, token: str | None = None) -> urllib.request.Request:
    headers = {"Accept": accept, "User-Agent": USER_AGENT}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return urllib.request.Request(url, headers=headers)


def _token() -> str:
    url = f"https://{REGISTRY}/token?scope=repository:{REPO}:pull&service={REGISTRY}"
    with urllib.request.urlopen(_request(url, "application/json"), timeout=30) as resp:
        return json.load(resp)["token"]


def _get_json(url: str, token: str, accept: str = ACCEPT) -> tuple[dict[str, Any], Any]:
    with urllib.request.urlopen(_request(url, accept, token), timeout=30) as resp:
        return json.load(resp), resp.headers


def resolve(tag: str) -> tuple[str, str]:
    """Return (IB_GATEWAY_VERSION, index_digest) for the given tag."""
    token = _token()
    base = f"https://{REGISTRY}/v2/{REPO}"
    index, headers = _get_json(f"{base}/manifests/{tag}", token)
    digest = headers.get("Docker-Content-Digest")
    if not digest:
        raise SystemExit(f"no Docker-Content-Digest header for {REPO}:{tag}")

    manifest = index
    if "manifests" in index:
        amd = next(
            (m for m in index["manifests"] if m.get("platform", {}).get("architecture") == "amd64"),
            None,
        )
        if amd is None:
            raise SystemExit(f"no amd64 manifest for {REPO}:{tag}")
        manifest, _ = _get_json(f"{base}/manifests/{amd['digest']}", token)

    config, _ = _get_json(
        f"{base}/blobs/{manifest['config']['digest']}", token, accept="application/octet-stream"
    )
    env = dict(entry.split("=", 1) for entry in config.get("config", {}).get("Env", []) if "=" in entry)
    version = env.get("IB_GATEWAY_VERSION")
    if not version:
        raise SystemExit(f"no IB_GATEWAY_VERSION env in {REPO}:{tag}")
    return version, digest


def rewrite(path: str, substitutions: list[tuple[re.Pattern[str], str]]) -> int:
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    new, count = text, 0
    for pattern, replacement in substitutions:
        new, hits = pattern.subn(replacement, new)
        if hits == 0:
            print(f"warning: no match in {path} for {pattern.pattern}", file=sys.stderr)
        count += hits
    if new != text:
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(new)
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", default="stable", help="upstream channel/tag to track (default: stable)")
    parser.add_argument("--check", action="store_true", help="report only; write nothing")
    args = parser.parse_args()

    version, digest = resolve(args.tag)
    pinned = f"{REGISTRY}/{REPO}:{version}@{digest}"

    with open("Dockerfile", encoding="utf-8") as fh:
        current = UPSTREAM_RE.search(fh.read())
    if current and current.group("ref").strip() == pinned:
        print(f"up-to-date: {pinned}")
        return 0

    print(f"available:  {version}  {digest}")
    if current:
        print(f"pinned:     {current.group('ref').strip()}")
    if args.check:
        return 1

    rewrite(
        "Dockerfile",
        [
            (UPSTREAM_RE, f"ARG UPSTREAM_IMAGE={pinned}"),
            (VERSION_RE, f"ARG IB_GATEWAY_VERSION={version}"),
        ],
    )
    rewrite("README.md", [(README_RE, rf"\g<1>{version}\g<2>")])
    print("changed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
