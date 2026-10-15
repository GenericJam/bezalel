# Study data: built ourselves, packs, the maintainer's content calls
- Date: 2026-10-15
- Status: accepted

## Context
studybible-mcp publishes an ~815 MB database, replaced in place (unpinnable),
with OpenAI embeddings that need a paid key and sqlite-vec on the phone. Some
of its content summarises in-copyright works; some is CC BY-NC.

## Decision
Build from its pipeline at a pinned commit (data/build.sh), split into five
zstd packs (core required), precompute similar passages with a local MIT model
so the phone needs no vector extension. Kevin's calls: Bezalel is free with no
ads ever, so CC BY-NC stays; summaries of in-copyright scholarship (Heiser,
Stott, Lennox, Bradley, Rillera, the synthesis) are included; full texts
(Heiser's papers and transcripts) are excluded.

## Consequences
data/SOURCES.md is the licence record and drives the attributions screen.
Packs are versioned and immutable on R2 (bezalel.genericjam.com); the manifest
is the only mutable object.
