"""Fetch the pinned sources studybible-mcp's own downloaders leave unpinned, and stage
every source into the checkout's data/ directory for its build scripts.

Runs with the checkout's Python (it imports the checkout's download_stepbible for
its file lists and checksums). Standard library only, plus the git and zstd CLIs.

  python sources.py --pins PINS --work WORK --checkout CHECKOUT

- STEPBible, BDB, Abbott-Smith (downloaded by the checkout's download_stepbible.py
  into WORK/cache) are checked against the checksums pinned in that script; its own
  check only warns about a cached file that differs.
- BibleAquifer resources, ACAI and Theographic come from sparse git checkouts at the
  commits in PINS (git verifies the content by commit hash). The checkout's
  downloaders take them from each repository's moving default branch.
- The openbible.info cross references are vendored (the published file is
  regenerated in place) and checked against PINS.
- The embedding model files are fetched by revision and checked against PINS.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent.parent


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def git(*args: str, cwd: Path | None = None) -> str:
    return subprocess.run(
        ["git", *args], cwd=cwd, check=True, capture_output=True, text=True
    ).stdout.strip()


def sparse_checkout(name: str, spec: dict, git_dir: Path) -> Path:
    """Check out only spec["paths"] of spec["repo"] at spec["commit"] into git_dir/name."""
    dest = git_dir / name
    if not (dest / ".git").exists():
        dest.mkdir(parents=True, exist_ok=True)
        git("init", "-q", cwd=dest)
        git("remote", "add", "origin", spec["repo"], cwd=dest)
    git("sparse-checkout", "set", "--no-cone", *[f"/{p}" for p in spec["paths"]], cwd=dest)
    have = subprocess.run(
        ["git", "cat-file", "-e", f"{spec['commit']}^{{commit}}"], cwd=dest, capture_output=True
    ).returncode == 0
    if not have:
        git("fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", spec["commit"], cwd=dest)
    git("-c", "advice.detachedHead=false", "checkout", "-q", "--force", spec["commit"], cwd=dest)
    head = git("rev-parse", "HEAD", cwd=dest)
    if head != spec["commit"]:
        sys.exit(f"{name}: HEAD is {head}, expected {spec['commit']}")
    if git("status", "--porcelain", cwd=dest):
        sys.exit(f"{name}: working tree differs from {spec['commit']}")
    for path in spec["paths"]:
        if not (dest / path).exists():
            sys.exit(f"{name}: {path} missing at {spec['commit']}")
    print(f"  {name}: {spec['commit'][:12]}")
    return dest


def link(target: Path, link_path: Path) -> None:
    link_path.parent.mkdir(parents=True, exist_ok=True)
    if link_path.is_symlink() or link_path.exists():
        link_path.unlink()
    link_path.symlink_to(target)


def check_stepbible(cache: Path, files: dict) -> None:
    for key, info in files.items():
        path = cache / info["filename"]
        if not path.exists():
            sys.exit(f"{key}: {path} missing (download_stepbible.py failed?)")
        if sha256_file(path) != info["sha256"]:
            sys.exit(f"{key}: {path} differs from the checksum pinned in download_stepbible.py")
    print(f"  STEPBible/BDB/Abbott-Smith: {len(files)} files match their pins")


def fetch_model(spec: dict, model_dir: Path) -> None:
    model_dir.mkdir(parents=True, exist_ok=True)
    for name, expected in spec["files"].items():
        dest = model_dir / Path(name).name
        if not dest.exists() or sha256_file(dest) != expected:
            url = f"https://huggingface.co/{spec['repo']}/resolve/{spec['revision']}/{name}"
            tmp = dest.with_suffix(dest.suffix + ".part")
            urllib.request.urlretrieve(url, tmp)
            if sha256_file(tmp) != expected:
                tmp.unlink()
                sys.exit(f"{url}: checksum mismatch")
            os.replace(tmp, dest)
    print(f"  embedding model {spec['repo']}@{spec['revision'][:12]}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pins", type=Path, required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--checkout", type=Path, required=True)
    args = parser.parse_args()

    pins = json.loads(args.pins.read_text())
    cache = args.work / "cache"
    git_dir = args.work / "git"
    data = args.checkout / "data"

    sys.path.insert(0, str(args.checkout / "scripts"))
    import download_stepbible as dl  # the checkout's own file lists and checksums

    print("Checking and fetching pinned sources")
    check_stepbible(cache, dl.FILES)

    sources = pins["git_sources"]
    checkouts = {name: sparse_checkout(name, spec, git_dir) for name, spec in sources.items()}

    # Stage everything the checkout's downloaders would have put under data/.
    for info in dl.FILES.values():
        link(cache / info["filename"], data / info["filename"])
    for sub in ("bsb", "lxx", "ancient_sources"):
        link(cache / sub, data / sub)

    expected = {f"aquifer_{key}" for key in dl.AQUIFER_RESOURCES}
    pinned = {name for name in sources if name.startswith("aquifer_")}
    if expected != pinned:
        sys.exit(f"Aquifer resources {sorted(expected)} do not match the pins {sorted(pinned)}")
    for key, info in dl.AQUIFER_RESOURCES.items():
        repo = sources[f"aquifer_{key}"]["repo"].rsplit("/", 1)[1]
        if f"/{repo}/" not in info["base"]:
            sys.exit(f"Aquifer {key}: the checkout reads {info['base']}, pinned {repo}")
        staged = 0
        for filename in info["files"]:  # the downloader's list; it skips absent files
            source = checkouts[f"aquifer_{key}"] / "eng" / "json" / filename
            if source.exists():
                link(source, data / info["dest"] / filename)
                staged += 1
        print(f"  aquifer {key}: {staged} files")

    if list(dl.ACAI_ENTITY_TYPES) != [p.split("/")[0] for p in sources["acai"]["paths"]]:
        sys.exit(f"ACAI types {dl.ACAI_ENTITY_TYPES} do not match the pinned paths")
    for entity_type in dl.ACAI_ENTITY_TYPES:
        link(checkouts["acai"] / entity_type / "json", data / "acai" / entity_type)

    xref = pins["openbible_cross_references"]
    xref_out = data / "cross_references" / "cross_references.txt"
    xref_out.parent.mkdir(parents=True, exist_ok=True)
    with open(xref_out, "wb") as out:
        subprocess.run(["zstd", "-dcq", str(DATA_DIR / xref["file"])], stdout=out, check=True)
    if sha256_file(xref_out) != xref["sha256"]:
        sys.exit(f"{xref['file']}: checksum mismatch")
    print("  openbible.info cross references (vendored)")

    fetch_model(pins["embedding_model"], cache / "model")


if __name__ == "__main__":
    main()
