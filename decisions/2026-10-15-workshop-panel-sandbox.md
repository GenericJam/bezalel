# What a built tool's panel lets through
- Date: 2026-10-15
- Status: accepted (bezalel-qyv.1); refines the panel host of
  2026-10-15-workshop-on-dyn.md and the boot-time reconcile of
  2026-10-15-workshop-shelf-follows-generation.md

## Context
A built tool's screen runs in its own process (`Bezalel.Workshop.Host`), and
the check keeps network modules out of built code. Three gaps were left
(review of the workshop-dyn branch, findings 3, 7, 9, 10, 12):

- The panel drew whatever the screen rendered. `Mob.UI` is allowed, and a
  `<WebView url=...>`, a `<Video src=...>` or an `<Image src="https://...">`
  makes the phone fetch a URL: a built tool could send study data or the
  clipboard off the phone, by mistake as much as by design.
- The host's crash reason went to the app's screen, which formatted it
  (`Exception.format_exit/1`): a built exception's `message/1` ran in the
  app's screen process, where a loop freezes the UI and a `send(self(), ...)`
  acts as the user. The view itself could carry a built struct into the
  renderer (`Mob.Sender`), and a prop Mob can't draw made every frame of the
  app fail while the panel was open.
- A watcher stopped the host with `:shutdown`, which a screen can trap;
  every Dyn activation reopened the panel (losing what the user typed); and
  the boot-time reconcile ran in `App.on_start`, which no test reaches.

## Decision
- The host sends a cleaned view. Web views, videos, camera previews and
  native views become a note. A `src` or `url` prop (also in a platform
  block, a `%Mob.Style{}` or under a string key) is kept only if it is a
  `plugin://` asset or a string (or an atom, read as its name) without `:`
  (an on-phone path); any
  scheme (`http`, `https`, `ftp`, `file`, `data`, ...) is dropped. `data:`
  URLs are dropped too: neither platform decodes them, so allowing them
  would gain nothing and leave a scheme to reason about. Native only fetches
  `http(s)` (case-sensitive), so the rule is stricter than needed on purpose.
  The check also refuses `Mob.UI.webview/1` and `camera_preview/1`
  (`partial`), and the guide tells the model, so a build learns it early.
- The view is plain data (structs other than `%Mob.Style{}` become maps) and
  is rendered once in the host against a do-nothing native layer
  (`Mob.Renderer.render/3` with `Host.DryRun`) before it is sent: a view Mob
  can't draw crashes the host (counted against the generation), not the
  app's frame.
- The host catches what its screen raises, throws or exits with, describes
  it with `Rho.Untrusted.format/4` (in a helper that is time-, heap- and
  600-byte-bounded, never ends in a crash report and dies with the host)
  and exits with `{:rho_crash, text}`, so the Keeper's crash report is that
  text. The app's screen only reads that (`Host.outcome/1`); any other
  reason (a link's exit, a kill) is described with
  `Rho.Untrusted.exit_text/2`, which is total and calls no protocol
  implementation and no `message/1`.
- The watcher kills the host when its owner exits, after telling the Keeper
  to stop watching it (the owner going away is not the screen's crash).
- The panel restarts on a Dyn event only if the version of its tool (the
  shelf row's generation) changed or its screen came or went. Not by module:
  every generation renames all its modules (`Dyn.G<n>.*`), unchanged ones
  too.
- `Workshop.reconcile/0` runs in `AppScreen.mount/3`, right after
  `Rho.Dyn.subscribe/0`, instead of `App.on_start`: the screen mounts at
  every start, and a revert while it was down is caught as well.

## Consequences
- An image from the network can't be shown in a tool; tools are offline by
  design. On-phone paths still work (a tool can't write files, so in
  practice only bundled `plugin://` assets).
- The panel's view is rendered twice (host and app); the panel is small.
- A screen that loops in `message/1` hangs its own host only; leaving the
  panel kills it after two seconds (a counted crash).
- The same guarantee in rho (the Keeper, the loop, tool results, selftests)
  is rho's: its formatting of Dyn terms happens in the process that ran
  them.
- Threat model (Kevin, 2026-10-15): this panel host, like rho's check, is a
  best-effort guard against a model's mistakes (a tool that draws a web
  view, crashes, or hangs), not a sandbox against hostile code; see
  2026-10-15-workshop-on-dyn.md.
