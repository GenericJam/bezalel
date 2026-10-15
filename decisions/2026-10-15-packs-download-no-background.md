# Pack downloads run in-process, without mob_background
- Date: 2026-10-15
- Status: accepted

## Context
The core pack is 26 MB compressed. mob_background keeps work alive in the
background, but on iOS it uses the audio background mode (Apple rejects that
for apps without audio) and on Android it needs a dataSync foreground service,
manifest/Kotlin edits and a Play declaration.

## Decision
Bezalel.Packs downloads while the app process lives, resumes with a Range
request from its part file after a drop or a restart, verifies both checksums
and renames the verified file over the old one. Core is offered on first
launch, not downloaded automatically.

## Consequences
Leaving the app can pause a download; it resumes on the next launch. See
lib/bezalel/packs.ex and data/README.md.
