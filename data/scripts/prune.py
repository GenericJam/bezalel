"""Delete the audited-out files (exclusions.json "delete_globs", reasons in
SOURCES.md) from a studybible-mcp checkout before its build scripts run, and
record fingerprints of them so check_packs.py can prove they did not ship.

  python prune.py --exclusions EXCLUSIONS --checkout CHECKOUT --fingerprints OUT.json

A fingerprint is up to WINDOWS evenly spaced runs of WORDS normalised words
(lowercased, punctuation dropped) from each deleted file. Fails if a glob matches
nothing, so a pin bump that moves the files is noticed rather than shipping them
under a new name.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

WORDS = 12
WINDOWS = 50


def normalise(text: str) -> list[str]:
    return re.sub(r"[^\w]+", " ", text.lower()).split()


def fingerprint(text: str) -> list[str]:
    words = normalise(text)
    if len(words) < WORDS:
        return []
    starts = range(0, len(words) - WORDS + 1, max(1, (len(words) - WORDS + 1) // WINDOWS))
    return [" ".join(words[i:i + WORDS]) for i in starts][:WINDOWS]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exclusions", type=Path, required=True)
    parser.add_argument("--checkout", type=Path, required=True)
    parser.add_argument("--fingerprints", type=Path, required=True)
    args = parser.parse_args()

    exclusions = json.loads(args.exclusions.read_text())
    fingerprints: dict[str, list[str]] = {}
    for pattern in exclusions["delete_globs"]:
        files = sorted(args.checkout.glob(pattern))
        if not files:
            sys.exit(f"{pattern} matches nothing in {args.checkout}")
        for path in files:
            name = str(path.relative_to(args.checkout))
            fingerprints[name] = fingerprint(path.read_text(encoding="utf-8", errors="replace"))
            path.unlink()
        print(f"  deleted {len(files)} files matching {pattern}")
    args.fingerprints.write_text(json.dumps(fingerprints, indent=1, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
