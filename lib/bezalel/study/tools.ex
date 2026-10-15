defmodule Bezalel.Study.Tools do
  @moduledoc """
  The study tools (`Rho.Tool` modules), ported from
  [studybible-mcp](https://github.com/djayatillake/studybible-mcp) (MIT,
  Copyright (c) 2024 Study Bible MCP Contributors; see NOTICE) at commit
  38cef28. They read the study packs through `Bezalel.Study.DB`. Each
  module's `run/2` returns the Markdown the model reads and `result/1` the
  same answer as data for the app's screens.

  `tier1/0` is the first set: text, lexicon, morphology, names, cross
  references and similar passages (the core pack) and the people in a
  passage (the graph pack).
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

  @doc "The tier 1 tool modules."
  @spec tier1() :: [module()]
  def tier1, do: @tier1
end
