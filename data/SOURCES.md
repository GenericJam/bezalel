# Study database: sources and licences

The licence audit for Bezalel's study database (bead `bezalel-e47.1`). Bezalel is
free and non-commercial: no price, no ads, no in-app purchases. On that basis
public domain, CC BY, CC BY-SA and CC BY-NC material is **in**; material still in
copyright without a grant is **out**. Audited at studybible-mcp
`38cef28dc2d7c1e834cbd5248edc0f65843e7819` (2026-10-14); every source below is
pinned in `pins.json` or by that commit's own download scripts.

The packs are built by `data/build.sh` (see `README.md`); `exclusions.json` lists
what is removed before the build, and `scripts/check_packs.py` checks that none of
it shipped.

## In

| Source | Supplies (table → pack) | Where from (pin) | Licence |
|---|---|---|---|
| STEPBible TAHOT, TAGNT (Tyndale House Cambridge) | Hebrew OT and Greek NT word by word with morphology, Strong's numbers and English glosses (`verses`, `passages` → core) | github.com/STEPBible/STEPBible-Data @ `043ffd0a` (sha256 per file in studybible-mcp `download_stepbible.py`) | CC BY 4.0 |
| STEPBible TFLSJ (formatted full LSJ), TBESG, TBESH | Greek lexicon; brief Greek/Hebrew lexicons (`lexicon` → core) | same | CC BY 4.0 |
| STEPBible TIPNR | Proper names (`names` → core) | same | CC BY 4.0 |
| STEPBible TEGMC, TEHMC | Morphology codes (`morphology` → core) | same | CC BY 4.0 |
| Brown-Driver-Briggs, unabridged (1906), formatted by Eliran Wong | Hebrew lexicon (`lexicon` → core) | github.com/eliranwong/unabridged-BDB-Hebrew-lexicon @ `6e8326c6` | Public domain |
| G. Abbott-Smith, *A Manual Greek Lexicon of the NT* (1922), TEI by translatable-exegetical-tools | Greek lexicon enrichment (`lexicon` → core) | github.com/translatable-exegetical-tools/Abbott-Smith @ `4048093c` | Public domain |
| Berean Standard Bible | **The English text `lookup_verse` shows** (`bsb_verses` → core); also the text the similar-passage vectors are computed from | bereanbible.com/bsb.txt (sha256 pinned in studybible-mcp `parsers/bsb.py`) | Public domain (dedicated by the publisher) |
| OpenBible.info cross references (Treasury of Scripture Knowledge plus votes) | `cross_references` → core (`type = 'tsk'`) | a.openbible.info/data/cross-references.zip, file dated 2026-10-12, vendored as `vendor/openbible-cross-references-2026-10-12.txt.zst` (the published file is regenerated in place) | CC BY 4.0 |
| ACAI Biblical Entity Data (BiblioNexus, via BibleAquifer) | People, places, groups, key terms (`acai_entities` → core) | github.com/BibleAquifer/ACAI @ `7e6a2d66` | CC BY-SA 4.0 |
| Torah Weave, Moshe Kline | Literary units of the Torah (`torah_weave_units`, `torah_weave_cells` → core) | `data/torah_weave/torah-units.json` in studybible-mcp (from chaver.com) | CC BY 4.0 |
| studybible-mcp (David Jayatillake and contributors) | The thematic cross-references (`thematic_references` → core), the schema, and the project's own prose below | github.com/djayatillake/studybible-mcp @ `38cef28d` | MIT |
| Similar verses and passages (computed here) | `similar_verses`, `similar_passages` → core | Vectors from BAAI/bge-small-en-v1.5 @ `5c38ec7c` (MIT model; the model is not shipped) over the BSB text | Derived from public-domain text; no attribution required |
| Aquifer Open Study Notes (Mission Mutual, adapted from Tyndale Open Study Notes) | `aquifer_content` (`study_notes`) → notes | github.com/BibleAquifer/AquiferOpenStudyNotes @ `bbb3f860` | CC BY-SA 4.0 |
| Aquifer Open Bible Dictionary (Mission Mutual, adapted from Tyndale Open Bible Dictionary) | `aquifer_content` (`dictionary`) → notes | github.com/BibleAquifer/AquiferOpenBibleDictionary @ `4d92a9ac` | CC BY-SA 4.0 |
| unfoldingWord Translation Notes | `aquifer_content` (`translation_notes_uw`) → notes | github.com/BibleAquifer/UWTranslationNotes @ `dbfb46e0` | CC BY-SA 4.0 |
| SIL Open Translator's Notes | `aquifer_content` (`translation_notes_sil`) → notes | github.com/BibleAquifer/SILOpenTranslatorsNotes @ `0ba58c29` | CC BY-SA 4.0 |
| FIA Key Terms (Word Collective) | `aquifer_content` (`key_terms`) → notes | github.com/BibleAquifer/FIAKeyTerms @ `91e4a774` | CC BY-SA 4.0 |
| ANE context entries (studybible-mcp, original summary prose naming standard reference works; Heiser is cited as one source among several in 11 of them) | `ane_entries`, `ane_book_mappings` → notes (102 of 120 entries, with `relig_008` and `cosmo_013` restored to their text before the *Lamb of the Free* additions; see Out) | `data/ane_context/` in studybible-mcp | MIT |
| John Owen (d. 1683), summaries written for studybible-mcp, linking CCEL texts | `theology_*` → notes (45 entries) | `data/owen/`, `data/reformed_evangelical/themes.json` | Owen's works: public domain; summaries: MIT |
| Theme taxonomy (studybible-mcp) | `theology_themes` → notes: the 17 themes, of 41 in `data/reformed_evangelical/themes.json`, that kept Owen entries use (or are parents of), two of them redefined (next row), with key works naming excluded authors dropped | `data/reformed_evangelical/themes.json` (trimmed by `scripts/prune.py`) | MIT |
| Five theme definitions written for Bezalel | `theology_themes` → notes: `atonement_models`, `image_of_god`, `corporate_headship` (used by Owen entries; their only definitions were in the excluded synthesis, Heiser and Bradley folders) and `penal_substitution`, `holy_spirit_work` (upstream text described Stott's arguments) | `added_themes.json` | Bezalel's own text |
| Rahlfs Septuagint (1935) morphology, OpenScriptorium lxx-morph (Seth Kushniryk, from Eliran Wong's digital edition), with its `verse_pairs.jsonl` mapping derived in part from STEPBible TVTMS | LXX text and morphology (`biblical_version_verses` → lxx) | github.com/OpenScriptorium/lxx-morph @ `c91f6b1e` (blob hashes pinned in studybible-mcp) | Morphology and mapping: CC BY 4.0; Rahlfs text: public domain |
| Brenton, *The Septuagint with Apocrypha* (1851), English and Greek, from eBible.org | `biblical_version_verses` → lxx | ebible.org eng-Brenton, grcbrent (sha256 per book pinned in studybible-mcp) | Public domain |
| Josephus, Perseus canonical-greekLit (Niese Greek, Whiston English, TEI) | `ancient_source_*` → ancient | github.com/PerseusDL/canonical-greekLit @ `01b725d8` | CC BY-SA 4.0 |
| Philo, First1KGreek (Cohn–Wendland Greek, Yonge English, TEI) | `ancient_source_*` → ancient | github.com/OpenGreekAndLatin/First1KGreek @ `03776b39` | CC BY-SA 4.0 |
| Targum Onkelos (Sefaria): Aramaic (Torat Emet) | `ancient_source_*` → ancient | github.com/Sefaria/Sefaria-Export-Archive @ `3f101363` | Public domain |
| Targum Onkelos English: Metsudah Chumash (Metsudah Publications, 2009), via Sefaria | `ancient_source_*` → ancient | same | **CC BY-NC 4.0** |
| Dead Sea Scrolls CD, 1QS, 1QSa, 1QpHab: ETCBC/dss (Abegg, Bowley, Cook) | `ancient_source_*` → ancient | github.com/ETCBC/dss @ `47ecc173` | **CC BY-NC 4.0** |
| Mishnah: Vilna (Romm, 1913) Hebrew; Joshua Kulp's *Mishnah Yomit* English, via Sefaria | `ancient_source_*` → ancient | Sefaria-Export-Archive @ `3f101363` | Hebrew: public domain; English: CC BY (3.0) |
| 1 Enoch: R. H. Charles (1912/1917), English Wikisource | `ancient_source_*` → ancient | Wikisource revisions pinned in studybible-mcp | Public domain |
| 4 Ezra: KJV Apocrypha (eBible.org eng-kjv) and Clementine Vulgate Latin (Latin Wikisource rev. 148869) | `ancient_source_*` → ancient | sha256/revision pinned in studybible-mcp | English: public domain (see note on the KJV); Latin transcription: CC BY-SA 4.0 |
| Ancient-source editorial notes and biblical links (studybible-mcp) | `ancient_source_notes`, `ancient_source_biblical_links` → ancient | `src/study_bible_mcp/corpora/` | MIT |
| Theographic Bible Metadata (Robert Rouse) | People, places, events, family edges, verse mentions (`graph_*` → graph) | github.com/robertrouse/theographic-bible-metadata @ `52e049ef` (People, Places, Events, PeopleGroups CSVs). Its rows carry Easton's Bible Dictionary text (1897, public domain) and OpenBible.info Bible Geocoding coordinates (CC BY 4.0) | CC BY-SA 4.0 |

The `ancient_source_passages` rows carry their own `edition`, `license`,
`original_license`, `translation_license` and source URL, so the app can show the
right credit beside each passage.

## Out

| Source | What it is | Why out |
|---|---|---|
| `data/heiser/` (Michael S. Heiser) | Full copies of in-copyright papers and Naked Bible podcast transcripts (`content/*.txt`; `monotheism_divine_plurality.txt` carries "Copyright 2008 The Institute for Biblical Research. All rights reserved."), entries summarising them section by section with page ranges, a catalogue of his books, and the textual-variant cases and LXX quotation hints whose records embed his analysis and his "Heiser Literal Translation" choices | In copyright, no grant. Tables left empty: `theology_*` rows by Heiser, `textual_variant_*`, `textual_*`, `nt_ot_lxx_quote_hints` |
| `data/stott/` (John Stott, d. 2011) | Chapter-by-chapter summaries of *The Cross of Christ*, *Basic Christianity*, and five Bible Speaks Today volumes | In copyright, no grant (Kevin's rule in PLAN.md) |
| `data/lennox/` (John Lennox) | Summaries of *Seven Days That Divide the World*, his Daniel and Joseph books | In copyright, no grant |
| 24 of the 41 themes in `data/reformed_evangelical/themes.json` | Topic definitions used only by the Stott and Lennox entries (e.g. `creation_genesis`, "Lennox's science-and-Scripture approach"; `deity_of_christ`, from *Basic Christianity*) | They describe the excluded books; trimmed by `scripts/prune.py` so the taxonomy holds only themes kept entries use |
| `data/bradley/` | Section-by-section summary of the paper "Two Fathers Only" (no public copy) | In copyright, no grant |
| Burnett, "So Shall Your Seed Be" (JSPL 5.2, 2015), and the Bradley/Gage John–Revelation spreadsheet | `ingest_burnett_gage.py` reads `data/Burnett-JSPL5.2.pdf` and `data/bradley_gage_john_rev.xlsx`, which are not in the repository | In copyright; not obtainable from the pin. Not run |
| 18 ANE entries from *Lamb of the Free* (Andrew Rillera, Cascade 2024), and that book's additions to two kept entries | `relig_012`–`relig_021`, `legal_009`, `death_008`, `gender_008`, `cosmo_015`, `method_005`–`method_008`, written by `ingest_lamb_of_free.py` and `ingest_atonement_synthesis.py` as summaries of that book; the same script appended parallels and notes to `relig_008` and `cosmo_013` | Same standard as Stott: summaries of one in-copyright work. Entries removed and the two kept ones restored to their earlier text by `exclusions.json` |
| `data/synthesis/` (atonement synthesis note and theme) | Two entries and a theme arguing a representation reading of the atonement, built on Bradley's paper and *Lamb of the Free* and pointing readers to the excluded ANE entries | Depends on excluded material; `ingest_atonement_synthesis.py` is not run |
| Harrison–Römhild cross references (`CH-CrossReference.xlsx`) | 57,614 `cross_references` rows (`type = 'ch'`) in the hosted database | No licence stated; the file is "requested from Robert Rouse / Viz.Bible", not published. Not obtainable from the pin |
| OpenAI embeddings (`verse_vectors`, `passage_vectors`) | `text-embedding-3-small` vectors of the STEPBible gloss text in the hosted database | Not licence-blocked, but not reproducible (an OpenAI key, a paid API, non-deterministic output, and the vectors in the hosted file can't be pinned). Replaced by `similar_verses`/`similar_passages`, computed here |

Tables in the hosted `study_bible.db` that no script at the pin builds, and which
are therefore not in our packs: `hlt_verses`, `hlt_annotations`,
`hlt_study_notes` (a draft "Heiser Literal Translation" with Heiser-derived notes)
and `verse_comparison_scores` (LLM-assigned scores).

## Attribution the app must show

The attributions screen (bead `bezalel-e47.6`) shows these, each with its link and
licence link (https://creativecommons.org/licenses/by/4.0/,
https://creativecommons.org/licenses/by-sa/4.0/,
https://creativecommons.org/licenses/by-nc/4.0/; the Mishnah English is CC BY 3.0,
https://creativecommons.org/licenses/by/3.0/). CC BY, BY-SA and BY-NC require
credit, a licence link, and an indication of our changes while keeping any earlier
ones (Aquifer's adaptation notices stay as written). Public-domain credits are
courtesy.

Above the list, the screen shows this modification notice, which covers every
CC-licensed item:

> Modified for Bezalel: the sources below were converted into SQLite databases,
> selected and excerpted, reformatted (for example HTML to plain text), re-keyed to
> Bible references, indexed for search, and split into downloadable packs. Their
> wording is otherwise unchanged.

(The repository has no public remote yet; when it or the pack host publishes
`data/README.md`, link the notice to it.)

Each string below also ends with "Modified." where the source is CC-licensed.
Strings to use verbatim:

1. **STEP Bible** — "Hebrew and Greek texts, morphology, lexicons and proper names
   from STEP Bible (www.STEPBible.org), created by Tyndale House, Cambridge.
   CC BY 4.0. Modified." Link: https://www.STEPBible.org
   (STEPBible asks for credit "to 'STEP Bible' linked to www.STEPBible.org".)
2. **Berean Standard Bible** — "The Holy Bible, Berean Standard Bible, BSB is
   produced in cooperation with Bible Hub, Discovery Bible, unfoldingWord, Bible
   Aquifer, OpenBible.com, and the Berean Bible Translation Committee. This text of
   God's Word has been dedicated to the public domain." Link: https://bereanbible.com
3. **Brown-Driver-Briggs** — "Brown-Driver-Briggs Hebrew and English Lexicon
   (1906), public domain; digital edition by Eliran Wong."
   Link: https://github.com/eliranwong/unabridged-BDB-Hebrew-lexicon
4. **Abbott-Smith** — "G. Abbott-Smith, A Manual Greek Lexicon of the New
   Testament (1922), public domain; TEI edition by the Abbott-Smith project."
   Link: https://github.com/translatable-exegetical-tools/Abbott-Smith
5. **OpenBible.info** — "Cross references from OpenBible.info, CC BY 4.0, drawing
   primarily on the Treasury of Scripture Knowledge. Place coordinates from
   OpenBible.info Bible Geocoding, CC BY 4.0. Modified." Links:
   https://www.openbible.info/labs/cross-references/ and https://www.openbible.info/geo/
6. **ACAI** — "ACAI Biblical Entity Data © 2024 by BiblioNexus is licensed under
   CC BY-SA 4.0. Modified." Link:
   https://github.com/BibleAquifer/ACAI
7. **Aquifer Open Study Notes** — "Aquifer Open Study Notes © 2026 Mission Mutual,
   licensed under CC BY-SA 4.0. This work is an adaptation of Tyndale Open Study
   Notes © 2023 Tyndale House Publishers, licensed under CC BY-SA 4.0. Modified."
   Link: https://github.com/BibleAquifer/AquiferOpenStudyNotes
8. **Aquifer Open Bible Dictionary** — "Aquifer Open Bible Dictionary © 2026
   Mission Mutual, licensed under CC BY-SA 4.0. This work is an adaptation of
   Tyndale Open Bible Dictionary © 2023 Tyndale House Publishers, licensed under
   CC BY-SA 4.0. Modified." Link: https://github.com/BibleAquifer/AquiferOpenBibleDictionary
9. **unfoldingWord** — "unfoldingWord® Translation Notes © 2022 unfoldingWord.
   Released under CC BY-SA 4.0. Modified." Link: https://github.com/BibleAquifer/UWTranslationNotes
10. **SIL** — "Open Translator's Notes © 2024 SIL International, licensed under
    CC BY-SA 4.0. Modified." Link: https://opentn.bible
11. **FIA Key Terms** — "Familiarization, Internalization, Articulation (FIA) Key
    Terms © 2025 Word Collective. Released under CC BY-SA 4.0. Modified."
    Link: https://github.com/BibleAquifer/FIAKeyTerms
12. **Theographic** — "Theographic Bible Metadata by Robert Rouse, CC BY-SA 4.0.
    Modified." Link:
    https://github.com/robertrouse/theographic-bible-metadata (its README asks
    users also to credit the original sources listed in its
    `docs/data-source-bibliography.md`; linking that file satisfies it).
13. **Torah Weave** — "Torah literary units dataset by Moshe Kline (chaver.com),
    CC BY 4.0. Modified." Link: https://chaver.com/torah-weave/
14. **Septuagint** — "LXX morphology data by Seth Kushniryk, CC BY 4.0, derived
    from Rahlfs Septuagint (Eliran Wong digital edition); versification mapping
    derived in part from TVTMS by STEPBible.org / Tyndale House Cambridge,
    CC BY 4.0. Rahlfs (1935) Greek text: public domain. Modified." Link:
    https://github.com/OpenScriptorium/lxx-morph
15. **Brenton** — "Sir Lancelot C. L. Brenton, The Septuagint with Apocrypha
    (1851), English and Greek, public domain, from eBible.org."
    Link: https://ebible.org/details.php?id=eng-Brenton
16. **Josephus** — "Josephus, Greek (Niese) and English (Whiston) from the Perseus
    Digital Library canonical-greekLit, CC BY-SA 4.0. Modified." Link:
    https://github.com/PerseusDL/canonical-greekLit
17. **Philo** — "Philo, Greek (Cohn–Wendland) and English (Yonge) from the
    First1KGreek project, CC BY-SA 4.0. Modified." Link:
    https://github.com/OpenGreekAndLatin/First1KGreek
18. **Targum Onkelos** — "Targum Onkelos, Aramaic text: public domain (Torat
    Emet); English: Metsudah Chumash, Metsudah Publications, 2009, CC BY-NC 4.0;
    both via Sefaria. Modified." Link: https://www.sefaria.org
19. **Dead Sea Scrolls** — "Dead Sea Scrolls transcription by Martin G. Abegg Jr.,
    James E. Bowley and Edward M. Cook, ETCBC/dss, CC BY-NC 4.0. Modified." Link:
    https://github.com/ETCBC/dss
20. **Mishnah** — "Mishnah, ed. Romm, Vilna 1913 (public domain); English: Joshua
    Kulp, Mishnah Yomit, CC BY 3.0; via Sefaria. Modified." Links:
    https://www.sefaria.org and https://creativecommons.org/licenses/by/3.0/
21. **1 Enoch** — "1 Enoch, translated by R. H. Charles (1912), public domain,
    from English Wikisource."
22. **4 Ezra** — "4 Ezra (2 Esdras 3–14): King James Version, from eBible.org;
    Latin: Clementine Vulgate from Latin Wikisource, CC BY-SA 4.0. Modified."
    Link: https://la.wikisource.org
23. **studybible-mcp** — "Study tools, ANE context, theology summaries and
    editorial notes adapted from studybible-mcp, Copyright (c) 2024 Study Bible MCP
    Contributors, MIT License." The MIT notice must accompany copies of substantial
    portions: include the full MIT licence text from the studybible-mcp
    `LICENSE` file on the attributions screen.

## Obligations that follow

- **Non-commercial (CC BY-NC):** the Dead Sea Scrolls and the Metsudah English are
  in the ancient pack. If Bezalel ever charges, shows ads or sells anything, those
  two must come out of the ancient pack first.
- **ShareAlike (CC BY-SA):** our adapted versions (the pack tables holding ACAI,
  Aquifer, Theographic, Josephus, Philo and the Latin 4 Ezra) must be offered under
  CC BY-SA 4.0. Each pack file is a collection of separately licensed tables and
  rows, so the BY-SA and BY-NC material are not merged into one adaptation. Say on
  the attributions screen that the database packs are available under the licences
  of their sources, and keep the packs downloadable as plain files (they are, from
  the hosting in `bezalel-e47.5`), which also keeps them outside app-store DRM.
- **KJV in the United Kingdom:** the Authorized Version is public domain everywhere
  except the UK, where the Crown's letters patent apply. It reaches the packs only
  as the English of 4 Ezra (2 Esdras 3–14). Low risk; noted for completeness.

## Questions for Kevin

1. **Summaries of in-copyright works.** studybible-mcp says its Heiser, Stott,
   Lennox, Bradley and Burnett entries are "original summary prose", not reproduced
   text. Summarising ideas is generally lawful, but these follow single books
   chapter by chapter (Heiser's with page ranges and the source texts sitting
   beside them), so under your rule they are out; so, for consistency, are the 18
   *Lamb of the Free* ANE entries, that book's additions to two kept entries, and
   the atonement synthesis built on Bradley and Rillera. Kept: the Owen summaries
   (public-domain works) and the ANE entries, which summarise scholarly consensus
   and cite Heiser or Walton among other sources. Confirm, or name any author to
   bring back (Lennox and Stott could also be asked for permission).
2. **Textual variants without Heiser.** `get_textual_variant` (30 MT/LXX/DSS cases)
   has no data because its dataset lives in `data/heiser/variants` and embeds
   Heiser's analysis and his translation choices. The manuscript evidence itself
   (readings, witnesses, dates) is factual; the cases could be rebuilt without the
   `heiser_analysis` and HLT fields if you want the tool.
