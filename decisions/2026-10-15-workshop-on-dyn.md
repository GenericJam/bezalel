# The Workshop builds real tools through rho's Dyn layer
- Date: 2026-10-15
- Status: accepted (bezalel-qyv.1, bezalel-qyv.2)

## Context
Phase 6 of PLAN.md: the Workshop's "Build" was a storyboard that always
made the design's sermon outline. rho's Dyn layer (from Operator) lets an
agent write Elixir tools and mob screens on the phone as generations:
checked, compiled and selftested, activated only with the human's
approval token, on probation afterwards (three crashes in a minute, or a
launch that dies, revert to the parent; two failed launches start in safe
mode). Several choices were open: what a build is, what built code may
call, how the user approves, where built tools show, and how the shelf
relates to the generations.

## Decision
- **A build is a rho loop** (`Bezalel.Workshop.Builder`) on the model from
  Settings with the Workshop's prompt (`Bezalel.Workshop.Prompt`: who it
  builds for, then rho's `Rho.Dyn.agent_guide/0`, which ends with
  Bezalel's conventions and a complete example that a test proves passes
  the pipeline) and the registry's tools: the study tools (to look at the
  data), the `dyn_*` tools, the current generation's tools. It ends with a
  proposal (a pending generation) or with the model's own words on why it
  has none. Without a credential the storyboard sample stays, and the
  Workshop says so as before; with one but no usable Dyn layer (no
  compiler, safe mode) it says why and builds the sample.
- **Conventions** let the Workshop read a generation without calling Dyn
  code: one file per tool, `Bezalel.Dyn.<Name>` (the `Rho.Tool`) and
  `Bezalel.Dyn.<Name>.Screen` (its screen). The title the user sees is the
  module name split at capitals ("Word Frequency").
- **Config** (`config :rho, :dyn`): namespace `Bezalel.Dyn`, app
  `:bezalel`, core `[Bezalel]`, allowed `[Bezalel.Workshop.Study]` only, a
  narrow read-only facade over the study tools that returns
  `{:ok, data} | {:error, message}` and never raises into Dyn code (a
  failure of Bezalel's own code must not count as the tool's crash). The
  check adds to rho's defaults: Mob gated to the drawing modules (no theme,
  `Mob.State`, device, files, notifications, wake-ups, web view); Req,
  ReqLLM, Finch, Mint, Exqlite, Ecto banned, and `:httpc`, `:gen_tcp`,
  `:gen_udp`, `:gen_sctp`, `:ssl`, `:inet`, `:socket`, `:dets`,
  `:disk_log`. So no network, no storage, nothing of the Library, packs,
  settings or secure store. MobBezalel (the style package) is outside the
  Core and allowed by default, which is what screens should draw with.
- **Screens** (`Bezalel.Workshop.Screens`): rho's mob screens with
  Bezalel's own rules for the agent. A tool's screen runs in its own
  process while its panel is open (`Bezalel.Workshop.Host`, Operator's
  front host cut down to one screen, no navigation, no native views); the
  app's screen only receives its expanded view tree and embeds it in the
  panel, between the tool's name and its buttons. A screen crash ends the
  host only; the panel says so and offers to open it again; the crash
  counts against its generation (the compiled `mount/3` registers the
  host with the Keeper).
- **Approval**: rho's `Rho.Dyn.Approval.Biometric` token store, confirmed
  by a plain sheet ("Add Word Frequency to Bezalel?", what it can and can't
  reach, what probation means). mob_biometric isn't a dependency and the
  tap on the sheet is the human's act; Dyn code can't reach the approval
  (Rho is Core) and no tool calls it. rho's agent-facing text names the
  host's way of approving through a new `hints: [approve: ...]` entry
  (rho commit in this change), so the model doesn't tell the user to use a
  screen lock.
- **Where tools show**: the Workshop's "Your tools" (with how each is
  doing: on probation, ready, change undone, taken out, off for now), a
  panel per tool, and the study agent, which takes its tools from the
  registry and withholds the `dyn_*` ones (`Bezalel.Agent.Live.withheld/0`),
  so a built tool is offered from the next model call after approval and
  gone after a revert. "Change the tool" builds again with the tool named
  (module, tool, files), on top of the current generation. Remove proposes
  a generation without the tool's files, approved on the same sheet; a
  tool whose code no longer runs just leaves the shelf.
- **Persistence**: the code is in rho's Dyn store (`dyn/` under rho's data
  dir: Documents on iOS, backed up, which is right for code the user made;
  re-downloadable data stays out of it). The `tools` table stays as the
  shelf: a `"dyn"` row names the module, tool, screen, files, the
  generation its last approved change made, and the build's session; how a
  tool is doing is computed from the Keeper (`Bezalel.Workshop.status/1`),
  not stored. Storyboard rows (`"sermon_outline"`) are unchanged, so no
  migration: both kinds share the table and render by `kind`. Build
  sessions go to `workshop/` under rho's data dir, apart from the
  conversations.
- **The compiler**: Dyn compiles on the phone. Both release paths keep
  `:compiler` (mob_dev's iOS release script and Android OTP bundle skip it,
  and `--slim` keeps what the app's `.app` closure needs, which includes
  it through `:elixir`), and debug deploys ship full OTP.
  `Bezalel.Workshop.compiler?/0` checks `:compile`, `:elixir_compiler`,
  `:elixir_erl` and `Kernel.ErrorHandler` load; without them the Workshop
  says so instead of failing a build.

## Consequences
- Built tools keep nothing between openings (no storage is allowed). A
  reading plan that remembers progress needs a per-tool store, a later
  decision.
- A development deploy that restarts the app within ten seconds of its
  first frame counts as a failed launch: an unproven generation is
  reverted at the next boot, and two in a row start in safe mode. Let the
  app run ten seconds (or send it to the background) before redeploying
  when a tool is on probation.
- The Dyn layer is on in host tests too; tests that build tools move the
  Keeper to a directory of their own (`test/support/dyn.ex`).
