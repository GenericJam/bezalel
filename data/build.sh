#!/usr/bin/env bash
# Rebuild the study-database packs from the pins (data/pins.json). See data/README.md.
#
#   data/build.sh
#
# Needs: git, uv, zstd, network. Writes only under data/work (checkout, downloads,
# full database) and data/out (packs, sizes, checks). Re-running reuses the
# verified downloads in data/work/cache and git/; delete data/work for a cold build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$HERE/work"
OUT="$HERE/out"
CHECKOUT="$WORK/studybible-mcp"
CACHE="$WORK/cache"
DB="$CHECKOUT/db/study_bible.db"
PINS="$HERE/pins.json"

pin() {  # pin a.b.c -> pins.json["a"]["b"]["c"]; uv finds or fetches a Python
  uv run --no-project --quiet python -c 'import functools, json, sys
print(functools.reduce(lambda d, k: d[k], sys.argv[2].split("."), json.load(open(sys.argv[1]))))' "$PINS" "$1"
}
REPO="$(pin studybible_mcp.repo)"
COMMIT="$(pin studybible_mcp.commit)"

# Reproducibility: one uv-managed CPython (and so one SQLite), fixed hash seed, UTC.
export UV_PYTHON="$(pin python)"
export UV_PYTHON_PREFERENCE=only-managed
export PYTHONHASHSEED=0 TZ=UTC PYTHONUTF8=1
export OMP_NUM_THREADS=1 OPENBLAS_NUM_THREADS=1 VECLIB_MAXIMUM_THREADS=1  # deterministic float math

step() { printf '\n==> %s\n' "$*"; }
their() { (cd "$CHECKOUT" && uv run --no-sync python "$@"); }
ours() { uv run --project "$HERE" --no-sync python "$@"; }

step "studybible-mcp at $COMMIT (clean checkout)"
mkdir -p "$WORK" "$CACHE" "$OUT"
if [[ ! -d "$CHECKOUT/.git" ]]; then
  git clone -q --filter=blob:none --no-checkout "$REPO" "$CHECKOUT"
fi
git -C "$CHECKOUT" cat-file -e "$COMMIT^{commit}" 2>/dev/null || git -C "$CHECKOUT" fetch -q origin "$COMMIT"
git -C "$CHECKOUT" -c advice.detachedHead=false checkout -q --force "$COMMIT"
git -C "$CHECKOUT" clean -q -ffdx -e /.venv
[[ "$(git -C "$CHECKOUT" rev-parse HEAD)" == "$COMMIT" ]]
[[ -z "$(git -C "$CHECKOUT" status --porcelain)" ]]
(cd "$CHECKOUT" && uv sync --locked -q)
uv sync --project "$HERE" --locked -q

step "Downloads pinned by studybible-mcp (checksum-verified)"
their scripts/download_stepbible.py --data-dir "$CACHE"
their scripts/download_bsb.py --data-dir "$CACHE/bsb"
their scripts/download_biblical_versions.py --data-dir "$CACHE/lxx"
their scripts/download_ancient_sources.py --data-dir "$CACHE/ancient_sources"

step "Sources pinned here; staging into the checkout"
their "$HERE/scripts/sources.py" --pins "$PINS" --work "$WORK" --checkout "$CHECKOUT"

step "Removing audited-out files (exclusions.json)"
their "$HERE/scripts/prune.py" --exclusions "$HERE/exclusions.json" --checkout "$CHECKOUT" \
  --fingerprints "$WORK/excluded_fingerprints.json"

step "studybible-mcp build"
their scripts/build_database.py --rebuild --data-dir data --db-path db/study_bible.db
their scripts/import_theographic.py --db-path db/study_bible.db \
  --data-dir "$WORK/git/theographic/CSV" --skip-download
their scripts/import_cross_references.py
their scripts/import_torah_weave.py
# Theological scholarship, as studybible-mcp's README applies it (ingest_burnett_gage.py
# needs files the repository doesn't have; see SOURCES.md).
their scripts/import_heiser_content.py db/study_bible.db
their scripts/import_bradley_content.py db/study_bible.db
their scripts/ingest_atonement_synthesis.py  # defines atonement_models, a parent theme of the next
their scripts/ingest_reformed_evangelical.py db/study_bible.db
their scripts/ingest_lamb_of_free.py

step "Similar verses and passages"
their "$HERE/scripts/embed_input.py" --checkout "$CHECKOUT" --db "$DB" --out "$WORK/verse_texts.tsv"
ours "$HERE/scripts/similar.py" --db "$DB" --texts "$WORK/verse_texts.tsv" --model "$CACHE/model"

step "Packs"
ours "$HERE/scripts/make_packs.py" --db "$DB" --packs "$HERE/packs.json" --pins "$PINS" --out "$OUT"

step "Checks"
ours "$HERE/scripts/check_packs.py" --packs "$HERE/packs.json" --exclusions "$HERE/exclusions.json" \
  --fingerprints "$WORK/excluded_fingerprints.json" --out "$OUT"
