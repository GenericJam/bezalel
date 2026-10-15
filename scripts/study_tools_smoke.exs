# Runs each study tool against the real packs (data/out, built by
# data/build.sh; not the test fixtures) and prints how long it took, the
# result's size and its first lines. Fails if any call returns an error or
# a tool in Bezalel.Study.Tools.all/0 isn't called.
#
#   mix run --no-start scripts/study_tools_smoke.exs [packs_dir]

alias Bezalel.Study.Tools

packs = List.first(System.argv()) || Path.expand("../data/out", __DIR__)
Application.put_env(:bezalel, :study_packs_dir, packs)

calls = [
  {Tools.LookupVerse, %{"reference" => "Ex 31:2-3"}},
  {Tools.LookupVerse, %{"reference" => "Matthew 1:23"}},
  {Tools.WordStudy, %{"strongs" => "H7307"}},
  {Tools.SearchLexicon, %{"query" => "wisdom", "language" => "hebrew"}},
  {Tools.SearchByStrongs, %{"strongs" => "H2451"}},
  {Tools.GetCrossReferences, %{"reference" => "Exodus 31:3"}},
  {Tools.ParseMorphology, %{"code" => "HVpp1cs", "language" => "hebrew"}},
  {Tools.LookupName, %{"name" => "Bezalel"}},
  {Tools.PeopleInPassage, %{"reference" => "Exodus 31"}},
  {Tools.FindSimilarPassages, %{"reference" => "Psalm 22:18"}},
  {Tools.ExploreGenealogy, %{"person" => "David"}},
  {Tools.ExplorePersonEvents, %{"person" => "Moses"}},
  {Tools.ExplorePlace, %{"place" => "Jerusalem"}},
  {Tools.FindConnection, %{"person1" => "Ruth", "person2" => "David"}},
  {Tools.GraphEnrichedSearch, %{"reference" => "Matthew 1:1"}},
  {Tools.GetStudyNotes, %{"reference" => "Exodus 31:3"}},
  {Tools.GetBibleDictionary, %{"topic" => "Tabernacle"}},
  {Tools.GetKeyTerms, %{"term" => "atonement"}},
  {Tools.GetAneContext, %{"reference" => "Genesis 1:6"}},
  {Tools.GetTheologyContext, %{"reference" => "Psalm 82:1"}},
  {Tools.GetTorahWeave, %{"reference" => "Exodus 31:3"}},
  {Tools.GetTextualVariant, %{"reference" => "Deuteronomy 32:8"}},
  {Tools.CompareBiblicalVersions, %{"reference" => "Psalm 82:6"}},
  {Tools.SearchAncientSources, %{"query" => "tabernacle"}},
  {Tools.LookupAncientSource, %{"citation" => "Antiquities 18.116"}},
  {Tools.ListResearchSources, %{"topic" => "septuagint"}}
]

IO.puts("packs: #{packs}\n")

missing = Enum.map(Tools.all(), & &1.name()) -- Enum.map(calls, fn {tool, _} -> tool.name() end)

failed =
  Enum.count(calls, fn {tool, args} ->
    {micros, result} = :timer.tc(fn -> tool.run(args, %{}) end)

    {status, text} =
      case result do
        {status, {:details, text, _data}} -> {status, text}
        result -> result
      end

    IO.puts(
      "== #{tool.name()} #{inspect(args)}: #{status}, #{byte_size(text)} bytes, " <>
        "#{div(micros, 1000)} ms"
    )

    text |> String.split("\n") |> Enum.take(6) |> Enum.each(&IO.puts("   " <> &1))
    IO.puts("")
    status != :ok
  end)

if missing != [], do: raise("not smoke-tested: #{Enum.join(missing, ", ")}")
if failed > 0, do: raise("#{failed} call(s) returned an error")
