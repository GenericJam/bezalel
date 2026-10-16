# Plan: a real agent for Bezalel

Status: agreed 2026-10-14; tracked in beads (`bd list`). Phase 6 (the
Workshop on Dyn) landed 2026-10-15: decisions/2026-10-15-workshop-on-dyn.md.

## Decisions taken

- The agent core comes out of `~/code/operator` into its own library, **rho**
  (the letter after pi), on GitHub (GenericJam/rho) and Hex, used by both
  Operator and Bezalel. Dyn (on-device tool and
  screen generation with approval, probation and revert) goes with it.
- Study tools come from studybible-mcp, without the MCP layer: their query
  logic ported to Elixir and called as ordinary tool modules. Python runs only
  on the Mac, to build the database.
- Bezalel is free and non-commercial. Users bring a model: subscription
  sign-in (Anthropic, OpenAI Codex) or an API key (Anthropic, OpenAI, Gemini).
  No key ships in the app: for store review, a Gemini key goes in the review
  notes for the reviewer to enter.
- The study database downloads on first launch, and the app can fetch newer
  versions as the library grows.
- No Rust. The loop waits on the network; Operator already runs it on phones
  in Elixir. Rust would add a precompiled native extension per platform.

- Images: the app must display images (from tools, models or the user),
  resized for the screen. Generating them is not tied to Gemini; whichever
  provider draws, the display path is the same.

## Phase 1: extract rho from Operator

From Operator (`lib/operator/core/`), about 5,500 lines plus Dyn's 6,500:

- Loop, Events, Session (omp/pi JSONL), Compaction, LLM contract and the
  req_llm adapter, Tool / ToolRunner / ToolRegistry, Models, Usage, Budget.
- Auth: the Anthropic and Codex OAuth flows, plus API keys (new) for
  Anthropic, OpenAI and Google through req_llm's existing providers.
- Dyn: engine, keeper, generations, store, registry, the Dyn tools; the
  generated namespace (`Operator.Dyn.*` today) becomes configuration.
- Operator-specific couplings become behaviours or config the host app
  supplies: data directory (`Operator.Paths`), secure credential storage,
  settings/fallback model, artifacts/attachments, clustering
  (`Operator.Cluster.Remote`), and Dyn's hooks into `Operator.Boot`, Files,
  Tflite and the Dyn menu.
- Operator's secure-store NIF (Keystore/Keychain) becomes a mob plugin, since
  both apps need it.
- Tests move with the code (loop, sessions, compaction, rate limits, OAuth,
  Dyn keeper/engine).
- Operator switches to the library and its copies are deleted, so there is
  one implementation.

Done when: Operator runs on the library on a phone (chat, tools, Dyn), the
library's tests pass in CI, and it is published.

## Phase 2: the study database

- Build with studybible-mcp's own pipeline, pinned to a commit, on the Mac.
- Content: everything licensed CC BY, CC BY-SA, CC BY-NC (non-commercial is
  fine for a free app) or public domain. Out unless permission is obtained:
  the copyrighted author material (`data/heiser` is "Copyright 2008 The
  Institute for Biblical Research"; Stott). Check `data/stott`, `lennox`,
  `bradley`, `owen` and the Aquifer/Tyndale licences file by file.
- Split into packs so the first download is small: core (Hebrew/Greek texts
  with morphology, lexicons, Strong's, names, cross-references, English text),
  then optional packs (study notes and dictionary, LXX, ancient sources).
  Measure each.
- Similar passages: precompute each verse's nearest neighbours at build time
  into a table, so the phone needs no vector extension.
- Hosting: Cloudflare R2 (no egress fees) with a versioned manifest (pack,
  version, size, sha256).
- An attributions screen listing every source and licence (CC BY and BY-SA
  require it).

## Phase 3: the study tools in Elixir

- Port the query layer (`database.py`, `tools.py`) against the same SQLite
  schema; each tool is a library tool module (`name`, `description`,
  `parameter_schema`, `run/2`).
- Tier 1: `lookup_verse`, `word_study`, `search_lexicon`,
  `search_by_strongs`, `get_cross_references`, `parse_morphology`,
  `lookup_name`, `people_in_passage`, `find_similar_passages`.
- Tier 2: genealogy, events, places, connections, study notes, dictionary,
  key terms, ANE/theology context, Torah weave, textual variants, LXX
  comparison, ancient sources, research sources.
- Their tool descriptions and hermeneutics prompts (MIT) become the system
  prompt and tool docs.
- Tests: their pytest expectations ported to ExUnit against a small fixture
  database.

## Phase 4: Bezalel on the real agent

- `Bezalel.Agent.Live` on the library loop; the storyboard stays for tests.
- Loop events drive the design's blocks: thinking as THINKING, each tool call
  as TOOL CALL (with its result), the answer as SUMMARY; cited verses as the
  passage card, lexicon words tappable.
- Streaming text, stop, steering a running reply.
- Conversations: the library's JSONL session is the transcript; Bezalel's
  SQLite keeps the shelf (name, kind, session id). Delete/Undo map onto
  session branches. The current Message table goes.
- Images: tool, model and attachment images shown in the chat and built
  tools, downscaled to the display size, tap to view full size.
- Settings: sign-in (Anthropic, Codex), API keys (Anthropic, OpenAI, Gemini),
  models from the library's registry, real usage.
- First launch: offer the core pack download with progress; Settings shows
  pack versions and "Check for updates". Done without mob_background: a
  download runs while the app process lives and resumes from its part file
  on the next launch.

## Phase 5: store review

A later step, after refinement. No key in the app: the review notes carry a
Gemini key and how to enter it (Settings → API keys), so the reviewer can
exercise every feature. The app must make that path obvious from a fresh
install.

## Phase 6: the Workshop on Dyn

- "Build" asks the agent to write a tool (and optionally a screen) through
  Dyn; the user approves it; it runs on probation and reverts on crashes.
- The built-tool panel renders Dyn screens; "Change the tool" edits the
  generation.
- The phone build must keep the Elixir compiler (no slim build).

## Order and dependencies

Phases 1 and 2 are independent and can run side by side. Phase 3 needs a
database from 2. Phase 4 needs 1 and 3. Phase 5 needs 4. Phase 6 needs 1 and
4.
