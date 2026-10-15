defmodule Bezalel.Study.Tools do
  @moduledoc """
  The study tools (`Rho.Tool` modules), ported from
  [studybible-mcp](https://github.com/djayatillake/studybible-mcp) (MIT,
  Copyright (c) 2024 Study Bible MCP Contributors; see NOTICE) at commit
  38cef28. They read the study packs through `Bezalel.Study.DB`. Each
  module's `run/2` returns the Markdown the model reads and `result/1` the
  same answer as data for the app's screens. `lookup_verse` and
  `word_study`'s `run/2` hand that data to rho as the result's details
  (`{:ok, {:details, markdown, result}}`), which the live agent turns into
  the passage card (`Bezalel.Agent.Card`).

  `all/0` is every tool, the set the live agent offers. `tier1/0` is the
  first set: text, lexicon, morphology, names, cross references and similar
  passages (the core pack) and the people in a passage (the graph pack).
  The rest read the graph (genealogies, events, places), notes (study
  notes, dictionary, key terms, ANE and theology context, textual
  variants), lxx (the Septuagint beside the Hebrew) and ancient (Second
  Temple sources) packs, the Torah weave in core, and a list of research
  sources shipped with the app.
  """

  alias Bezalel.Study.Tools

  @tier1 [
    Tools.LookupVerse,
    Tools.WordStudy,
    Tools.SearchLexicon,
    Tools.SearchByStrongs,
    Tools.GetCrossReferences,
    Tools.ParseMorphology,
    Tools.LookupName,
    Tools.PeopleInPassage,
    Tools.FindSimilarPassages
  ]

  @tier2 [
    Tools.ExploreGenealogy,
    Tools.ExplorePersonEvents,
    Tools.ExplorePlace,
    Tools.FindConnection,
    Tools.GraphEnrichedSearch,
    Tools.GetStudyNotes,
    Tools.GetBibleDictionary,
    Tools.GetKeyTerms,
    Tools.GetAneContext,
    Tools.GetTheologyContext,
    Tools.GetTorahWeave,
    Tools.GetTextualVariant,
    Tools.CompareBiblicalVersions,
    Tools.SearchAncientSources,
    Tools.LookupAncientSource,
    Tools.ListResearchSources
  ]

  @doc "Every study tool module."
  @spec all() :: [module()]
  def all, do: @tier1 ++ @tier2

  @doc "The tier 1 tool modules."
  @spec tier1() :: [module()]
  def tier1, do: @tier1
end
