# Runs each study tool once against the real packs (data/out, built by
# data/build.sh; not the test fixtures) and prints how long it took, the
# result's size and its first lines.
#
#   mix run --no-start scripts/study_tools_smoke.exs [packs_dir]

packs = List.first(System.argv()) || Path.expand("../data/out", __DIR__)
Application.put_env(:bezalel, :study_packs_dir, packs)

calls = [
  {Bezalel.Study.Tools.LookupVerse, %{"reference" => "Ex 31:2-3"}},
  {Bezalel.Study.Tools.WordStudy, %{"strongs" => "H7307"}},
  {Bezalel.Study.Tools.SearchLexicon, %{"query" => "wisdom", "language" => "hebrew"}},
  {Bezalel.Study.Tools.SearchByStrongs, %{"strongs" => "H2451"}},
  {Bezalel.Study.Tools.GetCrossReferences, %{"reference" => "Exodus 31:3"}},
  {Bezalel.Study.Tools.ParseMorphology, %{"code" => "HVpp1cs", "language" => "hebrew"}},
  {Bezalel.Study.Tools.LookupName, %{"name" => "Bezalel"}},
  {Bezalel.Study.Tools.PeopleInPassage, %{"reference" => "Exodus 31"}},
  {Bezalel.Study.Tools.FindSimilarPassages, %{"reference" => "Psalm 22:18"}}
]

IO.puts("packs: #{packs}\n")

failed =
  Enum.count(calls, fn {tool, args} ->
    {micros, result} = :timer.tc(fn -> tool.run(args, %{}) end)
    {status, text} = result

    IO.puts(
      "== #{tool.name()} #{inspect(args)}: #{status}, #{byte_size(text)} bytes, " <>
        "#{div(micros, 1000)} ms"
    )

    text |> String.split("\n") |> Enum.take(6) |> Enum.each(&IO.puts("   " <> &1))
    IO.puts("")
    status != :ok
  end)

if failed > 0, do: raise("#{failed} tool(s) returned an error")
