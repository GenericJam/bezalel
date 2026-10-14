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
- `android/.../MobBridge.kt` carries mob_new's merged, unreleased MOB-477
  (rounded clip, flexing `<Spacer/>`) and MOB-481 (`<Scroll anchor="bottom">`,
  which Study uses to open at and follow the newest message). Keep them if you
  regenerate the native project before mob_new ships them. The iOS side of
  MOB-481 comes from the local mob checkout.

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
- mob is the local checkout (`{:mob, path: "../mob"}`, `mob_dir` in the
  gitignored `mob.local.exs`): unreleased fixes are tried here before a
  release. Switch back to the Hex version once they ship.
- Check changes on devices: deploy, then
  `mix run --no-start scripts/app_tour.exs /tmp/app <node>...` walks every tab
  and the main interactions and saves screenshots. Android sheets are separate
  windows the in-app capture misses; use `adb exec-out screencap` for those.
- Host tests (`mix test`) mount the screen with `Mob.ScreenCase` against a
  temp database and temp `Mob.State`.

If you use [usage_rules](https://hexdocs.pm/usage_rules), `mix usage_rules.sync`
picks up `deps/mob/usage-rules.md`.
