# AGENTS.md: bezalel

Bezalel is a [Mob](https://hexdocs.pm/mob) app: Elixir on the BEAM,
running on the phone, rendering native SwiftUI / Jetpack Compose views. Screens
live in `lib/bezalel/`; `lib/bezalel/app.ex` starts the app.

## Where Mob's docs are

Read the docs for the mob version this app actually uses, in this order:

1. **`deps/mob/guides/*.md` and `deps/mob/usage-rules.md`**, after `mix deps.get`.
   These match the installed version exactly. (With a `path:` dependency on
   mob, read that checkout's `guides/` instead.)
2. **https://hexdocs.pm/mob/llms.txt**, the index of every page. Each page is
   also served as Markdown at `https://hexdocs.pm/mob/<page>.md`, e.g.
   https://hexdocs.pm/mob/screen_lifecycle.md. Hexdocs shows the latest
   release; check `mix.lock` if behaviour differs.
3. **`mix hex.docs fetch mob`** for offline docs, written to
   `~/.hex/docs/hexpm/mob/<version>/`.
4. **IEx**: `iex -S mix`, then `h Mob.Socket.start_async` (any module or
   function).

Guides to start with: `getting_started`, `screen_lifecycle` (including async
loading with `start_async/3` / `handle_async/3`), `components`, `events`,
`navigation`, `testing` (`Mob.ScreenCase`), `coming_from_liveview`.

## Rules for this app

- Load data asynchronously with `Mob.Socket.start_async/3` and handle the result
  in `handle_async/3` (LiveView's `start_async`; `assign_async` is a `:loading`
  assign plus `start_async`). Never a bare `Task.async` in a screen.
- Long or paginated lists use `<LazyList>` with `on_end_reached`. Mob has no
  `stream`.
- Write UI with the `~MOB` sigil.
- Test screens with `Mob.ScreenCase` (`mount_screen`, `render_event`,
  `render_info`, `render_async`).

## The design

- The source of truth is the Claude Design project "Bezalel Brand Foundation"
  (https://claude.ai/design/p/0eb39018-24f4-41b6-9643-8735d3de5a8e), copied to
  `design/`. `Bezalel Core Screens v2.dc.html` is the screen spec;
  `Bezalel Brand.dc.html` the brand. The `_ds/organic-…` system attached to the
  project is not used.
- The look comes from the **mob_bezalel** style package (`../mob_bezalel`,
  activated in `mob.exs`): themes, `MobBezalel.Palette` for colors with no
  theme slot, font tokens (`font: :display`, `:scripture`, `:hebrew`, …), and
  `MobBezalel.UI` composites (bars, cards, pills, segmented control, blocks,
  composer, sheet style). Use those; don't hard-code hex or sizes in screens.
  Fix look problems in mob_bezalel, not per screen.
- `Bezalel.DesignGalleryScreen` (Settings → Design specimen) shows every
  plugin piece; `mix run --no-start scripts/design_tour.exs /tmp/tour <node>...`
  captures it in every theme × cover over dist.
- `android/.../MobBridge.kt` carries mob_new's MOB-477 (rounded clip,
  flexing `<Spacer/>`) and MOB-481 (`<Scroll anchor="bottom">`, which Study
  uses to open at and follow the newest message), from mob_new 0.6.10. Keep
  them if you regenerate the native project. The iOS side of MOB-481 is in
  mob 0.9.18.

## The app

- `Bezalel.AppScreen` is the whole app: Study, Conversations, Workshop (and a
  built tool), Settings under one top bar and tab bar, plus the sheets and the
  toast. It holds the state; each tab's view and events are in
  `lib/bezalel/views/`. Events are `{:tap, {tab, event}}` tuples routed there.
- Data: `Bezalel.Library` (SQLite: conversations, messages, tools; seeds the
  design's Exodus 31 study on first run). Preferences: `Bezalel.Settings`
  (`Mob.State`). Scripture and lexicon: `Bezalel.Scripture` (Exodus 31
  sample). Models: `Bezalel.Models`.
- The agent and the tool builder are seams: `Bezalel.Agent` and
  `Bezalel.Workshop` behaviours, picked by `config :bezalel, :agent` /
  `:builder`. Today both are the design's storyboard (scripted replies; the
  builder makes only the sermon outline and says so for anything else).
  Settings tells the user replies are scripted; sign-in says it isn't built.
  A real model plugs in behind those behaviours, not in the views.
- To try an unreleased mob fix here first, point the dep at the checkout
  (`{:mob, path: "../mob", override: true}`) and set `mob_dir` to it in the
  gitignored `mob.local.exs` (native builds read mob's sources from there);
  go back to the Hex version once it ships.
- Check changes on devices: deploy, then
  `mix run --no-start scripts/app_tour.exs /tmp/app <node>...` walks every tab
  and the main interactions and saves screenshots. Android sheets are separate
  windows the in-app capture misses; use `adb exec-out screencap` for those.
- Host tests (`mix test`) mount the screen with `Mob.ScreenCase` against a
  temp database and temp `Mob.State`.

If you use [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/mob/usage-rules.md`.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
