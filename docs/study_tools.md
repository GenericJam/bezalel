# Study tools

Bezalel's study tools are [studybible-mcp](https://github.com/djayatillake/studybible-mcp)'s
query layer ported to Elixir (MIT, commit `38cef28`; see [NOTICE](../NOTICE)), run as
[rho](https://github.com/GenericJam/rho) tool modules with no MCP layer. They read the
study packs ([data/README.md](../data/README.md)).

## Modules

| Module | What |
|---|---|
| `Bezalel.Study.Tools` | `tier1/0`, the tool modules |
| `Bezalel.Study.Tools.*` | `LookupVerse`, `WordStudy`, `SearchLexicon`, `SearchByStrongs`, `GetCrossReferences`, `ParseMorphology`, `LookupName`, `PeopleInPassage`, `FindSimilarPassages`: each a `Rho.Tool` (`run/2` → the Markdown the model reads) with `result/1` (the same answer as data for the screens, e.g. `lookup_verse`'s words with their Strong's numbers) and `render/1` |
| `Bezalel.Study.DB` | Opens the packs read-only |
| `Bezalel.Study.Reference` | Book names and reference forms ("Ex 31:2-3", "Exodus 31", "Jn 3:16", "Jude 3") |
| `Bezalel.Study.Verses`, `Bezalel.Study.Lexicon` | Verse and lexicon queries |
| `Bezalel.Study.Format` | Shared Markdown (verses, lexicon entries) |
| `Bezalel.Study.Hermeneutics` | Genres and their guidance (Fee & Stuart) |
| `Bezalel.Study.Prompt` | The system prompt |
| `Bezalel.Study.Args`, `Bezalel.Study.Patterns` | Argument reading; the regexes, compiled at run time (mob_dev rule) |

## Pack access

`Bezalel.Study.DB.with_pack/2` opens the one pack a call needs, read-only, with Exqlite
directly, and closes it when the call ends. The directory is `config :bezalel,
:study_packs_dir` when set (tests: `test/fixtures/packs`; the smoke script: `data/out`),
else `Mob.data_dir()/packs`, where the app will download them.

Why not a second Ecto repo with the packs `ATTACH`ed: rho runs a reply's tool calls in
parallel, and a connection per call shares nothing between them, while a pool would hold
connections open across pack downloads (a new or replaced pack would need the repo
restarted, and `ATTACH` on every pooled connection for whichever packs exist). The tools
run fixed SQL on a fixed schema, so Ecto adds nothing. Opening a pack costs about a
millisecond on a Mac, beside a model round trip. A missing pack is an error result that
names it ("The graph study pack (people, places and events) isn't downloaded on this
device…"); a file that isn't a readable pack (a broken download) is an error too.

## Errors and empty results

studybible-mcp returns everything as text. Here, input the tool can't act on (no
reference, an unreadable one, an unknown book, chapter, verse, Strong's number or
morphology code, a bad `limit`) and a missing pack are `{:error, text}`, so rho marks the
result as an error; a search that finds nothing is `{:ok, text}`. The texts are
studybible-mcp's.

## Differences from studybible-mcp's output

Checked by running both on the same data (their handlers on the packs merged into one
database, 53 calls across the nine tools): every difference is one listed here, and
`find_similar_passages` matched exactly once their handler was given the precomputed
neighbours.

- `lookup_verse`: no Torah weave hint (`get_torah_weave` is tier 2), no textual-variant or
  NT↔OT quotation hints (no data in the packs); the cross-reference hint names only the
  TSK. Their verse-table-missing message is gone (a missing core pack is the pack error).
- `get_cross_references`: the core pack's only dataset is the Treasury of Scripture
  Knowledge (Harrison/Romhild isn't built; Gage/Bradley and Burnett are excluded), so the
  description, the `source` enum and the legend name only the TSK. The ranking is theirs
  restricted to TSK (votes, then target). Another `source` is an error.
- `find_similar_passages`: reads `similar_passages` (20 per verse, BGE-small vectors of
  the BSB) instead of sqlite-vec, so at most 20 results and no extension messages; the
  examples in the description are ones the packs give. "No similar passages" says the
  verse may not be in the database (every verse has neighbours).
- `lookup_name`: a relationship with several names prints "Cain, Abel, Seth" where Python
  printed "['Cain', 'Abel', 'Seth']".
- `people_in_passage`: an entity without a name shows its id instead of "None".
- A missing column value prints as nothing rather than "None".
- Genre of a written-out reference ("John 3:16") uses the full book-name table, not
  hermeneutics.py's shorter one, so more abbreviations get a genre line.
- A `limit` of zero, a negative number or text is the default (theirs passed it to SQL,
  where -1 meant no limit), except `lookup_name`, which keeps their error for a limit
  outside 1–20 and also refuses a fractional one (Python truncated 1.5 to 1). A number
  outside SQLite's 64-bit range is treated as unreadable. String arguments are trimmed.
- References and Strong's numbers take ASCII digits only ("Ps 22:18", "G26", not other
  scripts' numerals), where their `\d` patterns accepted any Unicode digit.
- Descriptions drop references to tools Bezalel doesn't have yet (`explore_genealogy`,
  `explore_person_events`, `explore_place`, `graph_enriched_search`, `get_study_notes`,
  `get_ane_context`); `parse_morphology` describes the Hebrew codes the packs use
  (STEPBible's, e.g. 'HVqp3ms').

## The system prompt

From their `prompts/system_prompt.md` and `hermeneutics.py`. Kept: the Fee & Stuart
principles, the seven-step reasoning pattern, the genre table (generated from
`Bezalel.Study.Hermeneutics`), the original-language format, the interpretation errors,
"when you don't know" and humility. Added: Bezalel's role (a sermon-prep companion for
pastors), and ground rules: look passages up and cite them; keep text and interpretation
apart; say what a tool returned versus what is inference; report tool errors and missing
packs instead of filling in from memory. The tool guidance covers the nine tier 1 tools.

Left out: the "Reading Scripture in its ancient context" section (populated divine realm,
derivation hierarchy, hourglass narrative, 1 Enoch, "recovery not novelty") and the
guidance for integrating ANE context. These present one school's framework (largely
Heiser's, whose material the packs exclude) as the default reading, and lean on
`get_ane_context`, a tier 2 tool. A general study companion for pastors of different
traditions should not take a side there by default. The translation-shift point (check
*nephesh*, *ruach* in their Hebrew range) stays, as a word-study habit.

## Tests and fixtures

`data/scripts/make_fixtures.py` cuts a small copy of each pack from `data/out` into
`test/fixtures/packs` (Genesis 1–2, Exodus 31, Psalm 22, John 3, Jude; about 4 MB in
all; its docstring lists what each table keeps). Tests in `test/bezalel/study/` run
against those, never `data/out`; they port studybible-mcp's handler tests and add the
Exodus 31 cases. `mix run --no-start scripts/study_tools_smoke.exs` runs each tool once
against the real packs.

## For tier 2

- The fixtures cover all five packs; widen `make_fixtures.py`'s chapter lists or
  filters for new tests (notes keeps only Exodus 31 and John 3; graph keeps only the
  edges among the chapters' people).
- `get_torah_weave` (core) can bring back `lookup_verse`'s Torah weave hint;
  `compare_biblical_versions` and `graph_enriched_search` need two packs: two
  `with_pack/2` calls (or a connection that `ATTACH`es the second pack).
- `ancient` uses FTS5; check the phone's exqlite build has it.
- If ANE context comes back, its prompt guidance should present it as background with
  its sources, not as the default reading frame.
- No data for `get_textual_variant` (excluded material).
