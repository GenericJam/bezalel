# The Workshop's shelf follows the generation that runs
- Date: 2026-10-15
- Status: accepted (bezalel-qyv.1); refines the persistence part of
  2026-10-15-workshop-on-dyn.md. Where it runs at start is refined by
  2026-10-15-workshop-panel-sandbox.md (`AppScreen.mount/3`, not
  `App.on_start`).

## Context
The shelf (`tools` rows of kind `"dyn"`) recorded each tool as of its last
approved change: Remove deleted the row, a Change overwrote its request and
generation. The Keeper can undo either: three crashes on probation revert at
once (an event the app hears), and a launch that dies reverts at the next
boot, before any screen subscribes. A reverted Remove brought the tool back
with no row, so the user couldn't see or remove it; a reverted Change left
the row with the undone change's request.

## Decision
- A row keeps one **version per approved change** (`data["versions"]`:
  generation, request, model, build session; a removal is
  `"removed" => true`). Approving a Remove adds a removal and marks the row
  removed (`Library.list_tools/0` and `get_tool/1` skip it) instead of
  deleting it.
- `Bezalel.Workshop.reconcile/0` puts every row in line with the Keeper's
  current generation and its ancestors: the newest version in that line is
  the one shown (request, model, generation, session; tool, screen and
  files as that generation has them). A removal there keeps it off the
  shelf; a revert that drops the removal brings it back. A row with no
  version in the line (a new tool that was reverted) stays as it is and
  its status says it was taken out. A tool that runs with no row gets one,
  named after its module, with the request (rationale) of the generation
  that added it.
- It runs at app start (`Bezalel.App.on_start`, after the migrations:
  boot reverts happen with nobody listening) and on every `:reverted`
  event (`Bezalel.Views.Workshop.dyn_event/2`, before the shelf is
  redrawn).
- `Bezalel.Workshop.status/1` reads the newest version: a reverted change
  is "Change undone", a reverted removal "Back: removing it was undone".
- Removed rows aren't deleted: they're small, and rho's `revert_to/3` can
  make any once-active generation current again.

## Consequences
- Rows from before this change have no versions; reconcile leaves them as
  they are (only development devices had any).
- Bezalel's check config no longer bans `:mob_nif` itself: rho's defaults
  do, from rho a8f3b59 (pinned at eb1026b) on.
