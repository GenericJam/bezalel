defmodule Bezalel.Study.Tools.LookupVerseTest do
  # Ported from studybible-mcp's tests/test_lookup_verse.py, against the
  # fixture packs (test/fixtures/packs: Genesis 1-2, Exodus 31, Psalm 22,
  # John 3 and Jude from the real core pack).
  use ExUnit.Case, async: true

  alias Bezalel.Study.Tools.LookupVerse

  defp lookup(reference, args \\ %{}) do
    {:ok, text} = LookupVerse.run(Map.put(args, "reference", reference), %{})
    text
  end

  defp error(reference) do
    {:error, message} = LookupVerse.run(%{"reference" => reference}, %{})
    message
  end

  # The verse headings ('## Exo.31.2', a single verse's with " (BSB)"), in order.
  defp headings(text) do
    for [_, ref] <- Regex.scan(~r/^## (\S+\.\d+\.\d+\S*)(?: \(BSB\))?$/m, text), do: ref
  end

  defp occurrences(text, part), do: text |> String.split(part) |> Enum.count() |> Kernel.-(1)

  test "a verse range returns every verse in order under the range's heading" do
    text = lookup("Ex 31:2-3")
    assert headings(text) == ["Exo.31.2", "Exo.31.3"]
    assert text =~ ~r/\A# Ex 31:2-3 \(BSB\)\n/
  end

  test "an en dash separates a range" do
    assert headings(lookup("Exodus 31:2\u20133")) == ["Exo.31.2", "Exo.31.3"]
  end

  test "a whole chapter returns the chapter" do
    text = lookup("Exodus 31")
    assert headings(text) == for(v <- 1..18, do: "Exo.31.#{v}")
    assert text =~ ~r/\A# Exodus 31 \(BSB\)\n/
  end

  test "a cross-chapter range" do
    assert headings(lookup("Genesis 1:30-2:2")) == ["Gen.1.30", "Gen.1.31", "Gen.2.1", "Gen.2.2"]
  end

  test "an OT verse stored with split English(Hebrew) numbering is found by its English number" do
    assert headings(lookup("Psalm 22:1")) == ["Psa.22.1(22.2)"]
    assert headings(lookup("Psalm 22:1-2")) == ["Psa.22.1(22.2)", "Psa.22.2(22.3)"]
  end

  test "a single verse is the plain verse, BSB-labelled, with its word list and cross-reference hint" do
    text = lookup("Exodus 31:3")
    assert text =~ ~r/\A## Exo.31.3 \(BSB\)\n\nAnd I have filled him with the Spirit of God/
    assert text =~ "### Word Analysis"
    assert text =~ "(H7307G): [the] spirit of\n"
    assert text =~ "(H2451): with/ skill\n"
    assert text =~ "(H4390): and/ I have filled\n"
    assert text =~ "## Genre: Old Testament Narratives"
    assert text =~ "`get_cross_references` (reference='Exodus 31:3')"
  end

  test "the passage hints come once, pointing at the passage's first verse" do
    text = lookup("Psalm 22:0-2")
    assert occurrences(text, "## Genre:") == 1
    assert occurrences(text, "get_cross_references") == 1
    assert text =~ "(e.g. reference='Psalm 22:1')"
  end

  test "the original-text and morphology flags apply to every verse" do
    plain = lookup("John 3:16-18", %{"include_original" => false})
    refute plain =~ "### Original Text"
    refute plain =~ "### Word Analysis"

    parsed = lookup("John 3:16-18", %{"include_morphology" => true})
    assert occurrences(parsed, "### Original Text") == 3
    assert occurrences(parsed, "### Word Analysis") == 3
    assert parsed =~ "(G0025): loved [V-AAI-3S]"
  end

  test "a passage omits the word list unless morphology is requested" do
    passage = lookup("John 3:16-18")
    assert occurrences(passage, "### Original Text") == 3
    refute passage =~ "### Word Analysis"
  end

  test "more than 50 verses are cut, with the continuation named" do
    text = lookup("Genesis 1-2")
    found = headings(text)
    assert Enum.count(found) == 50
    assert List.last(found) == "Gen.2.19"
    assert text =~ ~r/\A# Genesis 1:1-2:19 \(BSB\)\n/

    assert text =~
             "*Showing the first 50 of 56 verses. Continue with reference='Genesis 2:20-25'.*"
  end

  test "a range past the chapter's end is clamped with a note" do
    text = lookup("Exodus 31:17-40")
    assert headings(text) == ["Exo.31.17", "Exo.31.18"]
    assert text =~ "*Exodus 31 ends at verse 18; showing through 31:18.*"
  end

  for {reference, message} <- [
        # The fixture has a few Exodus chapters, so not 1–40.
        {"Exodus 41", "Exodus has no chapter 41 (chapters "},
        {"Exodus 31:30", "Exodus 31 has no verse 30 (verses 1–18)."},
        {"Exodus 31:5-3", "Invalid range 'Exodus 31:5-3': the end comes before the start."},
        {"Nonsense 1:1", "Unknown book 'Nonsense'"},
        {"what is love", "Supported forms: a verse ('John 3:16'), a verse range"},
        {"", "Please provide a verse reference"}
      ] do
    test "#{inspect(reference)} is an error the model can act on" do
      assert error(unquote(reference)) =~ unquote(message)
    end
  end

  test "single-chapter books are cited by verse alone" do
    assert headings(lookup("Jude 3")) == ["Jud.1.3"]
    assert headings(lookup("Jude 3-5")) == ["Jud.1.3", "Jud.1.4", "Jud.1.5"]
    assert Enum.count(headings(lookup("Jude"))) == 25
    # A lone "1" is the chapter, as chapter-level tools expect.
    assert Enum.count(headings(lookup("Jude 1"))) == 25
  end

  test "a Psalm superscription is labelled and shown without counting as a verse" do
    text = lookup("Psalm 22:0-2", %{"include_original" => false})
    assert text =~ "## Psa.22 superscription (Hebrew Psa.22.1)"
    refute text =~ "Psa.22.0(22.1)"
    assert headings(text) == ["Psa.22.1(22.2)", "Psa.22.2(22.3)"]
    assert text =~ ~r/\A# Psalm 22:1-2 \(BSB\)/

    chapter = lookup("Psalm 22", %{"include_original" => false})
    assert chapter =~ ~r/\A# Psalm 22 \(BSB\)\n/
    assert Enum.count(headings(chapter)) == 31
  end

  test "result/1 gives the passage card its words with Strong's numbers" do
    {:ok, result} = LookupVerse.result(%{"reference" => "Ex 31:2-3"})
    assert result.book == "Exo"
    assert result.label == "Ex 31:2-3"
    assert [bezalel_verse, spirit_verse] = result.verses
    assert bezalel_verse.reference == "Exo.31.2"
    assert bezalel_verse.bsb
    assert bezalel_verse.english =~ "Bezalel son of Uri"
    assert %{gloss: "Bezalel"} = Enum.find(bezalel_verse.words, &(&1.strongs == "H1212G"))
    assert ~w(H4390 H7307G H2451) -- Enum.map(spirit_verse.words, & &1.strongs) == []
  end
end
