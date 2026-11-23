#!/usr/bin/env python3
"""Merge one model group's release notes into a release that holds every model.

The release workflow builds the model groups (MODEL_GROUPS in release.yml) one after
the other; each adds its .bin files to the same release, and runs this to rewrite the
release's notes with its own parts (make-app.sh's release-parts/):

    release-notes.py BODY PARTS GROUP > NEW_BODY

BODY is the release's current notes (an empty file for a new release), PARTS the build's
release-parts/ folder, GROUP the group's name. What each group added is kept in a hidden
comment at the end of the notes, so a group built on a later run (after a failed build)
is merged with the others, and a rebuilt group replaces its own rows. Groups are listed in
MODEL_GROUPS order; a group not built yet is named as missing.
"""

import base64
import json
import os
import re
import sys

STATE_RE = re.compile(r"<!-- release-state: ([A-Za-z0-9+/=]+) -->")


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def rows(text):
    return [line for line in text.splitlines() if line.startswith("|")]


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    body_file, parts, group = sys.argv[1:]
    groups = json.loads(os.environ["MODEL_GROUPS"])
    names = [g["name"] for g in groups]
    if group not in names:
        sys.exit(f"unknown group {group!r} (MODEL_GROUPS: {', '.join(names)})")

    state = {}
    m = STATE_RE.search(read(body_file))
    if m:
        state = json.loads(base64.b64decode(m.group(1)))
    state[group] = {
        "header": read(os.path.join(parts, "header.md")).strip(),
        "bins": rows(read(os.path.join(parts, "bins.md"))),
        "inputs": rows(read(os.path.join(parts, "inputs.md"))),
        "extra": read(os.path.join(parts, "extra.md")).strip(),
    }
    if not state[group]["header"] or not state[group]["bins"]:
        sys.exit(f"{parts}: no release notes parts (header.md, bins.md)")

    built = [g for g in groups if g["name"] in state]
    missing = [g for g in groups if g["name"] not in state]
    out = [state[built[0]["name"]]["header"], "", "### Files", ""]
    out += ["| File | Model | CPU | Size | SHA-256 |", "|---|---|---|---|---|"]
    for g in built:
        out += state[g["name"]]["bins"]
    for g in missing:
        out += ["", f"The {g['title']} are not in this release yet: the next run adds them."]
    out += ["", "Inputs (sha256):", "", "| CPU | Docker Engine | docker compose |", "|---|---|---|"]
    for g in built:
        out += state[g["name"]]["inputs"]
    extras = [state[g["name"]]["extra"] for g in built if state[g["name"]]["extra"]]
    if extras:
        out += [""] + extras
    encoded = base64.b64encode(json.dumps(state, sort_keys=True).encode()).decode()
    out += ["", f"<!-- release-state: {encoded} -->"]
    print("\n".join(out))


if __name__ == "__main__":
    main()
