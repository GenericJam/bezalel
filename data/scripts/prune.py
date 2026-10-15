"""Remove the audited-out material (exclusions.json, reasons in SOURCES.md) from a
studybible-mcp checkout before its build scripts run.

  python prune.py --exclusions EXCLUSIONS --added-themes ADDED --checkout CHECKOUT

1. Deletes the excluded data folders and ANE entries.
2. Restores ANE entries that an excluded ingest augmented to their text at the
   commit before it (read with git from the checkout's history).
3. Trims the theme taxonomy the kept importer loads
   (data/reformed_evangelical/themes.json) to the themes kept entries use, and
   their parents, since the rest describe the excluded authors' books; puts in
   ADDED's definitions (replacing any with the same key); and drops key works that
   name excluded authors.

Fails if anything it is told to remove or restore is missing, so a pin bump that
moves the material is noticed rather than silently shipping it under a new name.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

THEOLOGY_CONTENT = ("owen",)  # the kept theology content folders
TAXONOMY = "reformed_evangelical/themes.json"


def write_json(path: Path, document: dict) -> None:
    path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def remove_ane_entries(data: Path, by_file: dict) -> None:
    for filename, ids in by_file.items():
        if filename.startswith("_"):
            continue
        path = data / "ane_context" / filename
        document = json.loads(path.read_text(encoding="utf-8"))
        missing = sorted(set(ids) - {entry["id"] for entry in document["entries"]})
        if missing:
            sys.exit(f"{path}: excluded entries {missing} not found")
        document["entries"] = [e for e in document["entries"] if e["id"] not in ids]
        write_json(path, document)
        print(f"  data/ane_context/{filename}: removed {len(ids)} entries")


def restore_ane_entries(checkout: Path, spec: dict) -> None:
    for filename, ids in spec["entries"].items():
        old = json.loads(subprocess.run(
            ["git", "show", f"{spec['commit']}:data/ane_context/{filename}"],
            cwd=checkout, check=True, capture_output=True, text=True,
        ).stdout)
        originals = {e["id"]: e for e in old["entries"] if e["id"] in ids}
        path = checkout / "data" / "ane_context" / filename
        document = json.loads(path.read_text(encoding="utf-8"))
        current = {e["id"] for e in document["entries"]}
        missing = sorted(set(ids) - (set(originals) & current))
        if missing:
            sys.exit(f"{path}: entries to restore {missing} not found")
        document["entries"] = [originals.get(e["id"], e) for e in document["entries"]]
        write_json(path, document)
        print(f"  data/ane_context/{filename}: restored {sorted(ids)} from {spec['commit'][:12]}")


def prune_themes(data: Path, added_path: Path, excluded_authors: list[str]) -> None:
    used = {
        key
        for folder in THEOLOGY_CONTENT
        for path in sorted((data / folder / "content").glob("*.json"))
        for entry in json.loads(path.read_text(encoding="utf-8"))["entries"]
        for key in entry.get("themes", [])
    }
    path = data / TAXONOMY
    document = json.loads(path.read_text(encoding="utf-8"))
    added = {t["theme_key"]: t for t in json.loads(added_path.read_text(encoding="utf-8"))["themes"]}
    definitions = {**{t["theme_key"]: t for t in document["themes"]}, **added}

    keep, frontier = set(), set(used)
    while frontier:  # used themes and all their ancestors
        key = frontier.pop()
        if key in keep:
            continue
        if key not in definitions:
            sys.exit(f"Theme {key!r} is used by kept entries but defined nowhere")
        keep.add(key)
        if definitions[key].get("parent_theme"):
            frontier.add(definitions[key]["parent_theme"])
    unneeded = sorted(set(added) - keep)
    if unneeded:
        sys.exit(f"{added_path}: themes {unneeded} are not used by kept entries; remove them")

    before = len(document["themes"])
    order = [t["theme_key"] for t in document["themes"]] + sorted(set(added) - {t["theme_key"] for t in document["themes"]})
    themes = []
    for key in order:
        if key not in keep:
            continue
        theme = dict(definitions[key])
        theme["key_works"] = [
            work for work in theme.get("key_works", [])
            if not any(author in work for author in excluded_authors)
        ]
        themes.append(theme)
    document["themes"] = themes
    write_json(path, document)
    print(f"  data/{TAXONOMY}: {len(themes)} of {before} themes kept, {len(added)} from {added_path.name}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--exclusions", type=Path, required=True)
    parser.add_argument("--added-themes", type=Path, required=True)
    parser.add_argument("--checkout", type=Path, required=True)
    args = parser.parse_args()

    exclusions = json.loads(args.exclusions.read_text())
    data = args.checkout / "data"

    for name in exclusions["data_dirs"]:
        path = data / name
        if not path.is_dir():
            sys.exit(f"Excluded directory {path} does not exist")
        shutil.rmtree(path)
        print(f"  removed data/{name}")

    remove_ane_entries(data, exclusions["ane_entry_ids"])
    restore_ane_entries(args.checkout, exclusions["ane_entry_restore"])
    prune_themes(data, args.added_themes, exclusions["excluded_authors"])


if __name__ == "__main__":
    main()
