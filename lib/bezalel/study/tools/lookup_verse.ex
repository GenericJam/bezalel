defmodule Bezalel.Study.Tools.LookupVerse do
  @moduledoc """
  `lookup_verse`: a verse, range or chapter in English (BSB) and in Hebrew
  or Greek, word by word with Strong's numbers.

  Ported from studybible-mcp's `handle_lookup_verse` (MIT). Same text,
  without the hints for tools and data Bezalel doesn't have: Torah weave
  partners and textual variants / NT↔OT quotation forms (no data in the
  packs); the cross-reference hint names only the TSK, the one
  cross-reference set in the core pack.

  `result/1` returns the passage as data (`t:Bezalel.Study.Format.verse_view/0`
  rows: each word with its Strong's number) for the passage card.
  """
  @behaviour Rho.Tool

  alias Bezalel.Study.{Args, DB, Format, Hermeneutics, Reference, Verses}

  # Upper bound on verses per call; longer passages (Psalm 119) are cut with
  # a note naming the continuation.
  @max_verses 50

  @forms "a verse ('John 3:16'), a verse range ('Luke 19:1-3'), a cross-chapter " <>
           "range ('Luke 19:45-20:2'), or a whole chapter ('Psalm 23')"

  @impl true
  def name, do: "lookup_verse"

  @impl true
  def description do
    """
    Look up the text of a Bible verse, verse range, or whole chapter, in English and in the original language.

    Returns, for each verse in canonical order:
    - The English text: the Berean Standard Bible (BSB), or STEPBible's word
      gloss marked [gloss] where the BSB lacks the verse
    - The original Greek/Hebrew text (optional, on by default)
    - A word-by-word breakdown with Strong's numbers and glosses (single verses;
      for a passage only when include_morphology is set)
    - Optional grammatical parsing for each word

    And once for the passage:
    - Genre-specific interpretive background for the passage's literary type
    - A pointer to the passage's cross-references

    Accepts 'John 3:16', 'Luke 19:1-3', cross-chapter ranges such as
    'Luke 19:45-20:2', and whole chapters such as 'Psalm 23'. Single-chapter books
    may be cited by verse alone ('Jude 3', 'Philemon 6', '3 John 4'); 'Jude 1' is the
    whole chapter. Numbering is English; a Psalm superscription (verse 1 in the
    Hebrew) is labelled as the superscription. Returns at most #{@max_verses} verses per
    call, with a note naming the reference that continues a longer passage.

    Relevant whenever the verified wording of a passage, or its original-language
    form, is needed.\
    """
  end

  @impl true
  def parameter_schema do
    %{
      "type" => "object",
      "properties" => %{
        "reference" => %{
          "type" => "string",
          "description" =>
            "Bible reference (e.g., 'John 3:16', 'Luke 19:1-3', 'Luke 19:45-20:2', or a whole chapter such as 'Psalm 23')"
        },
        "include_original" => %{
          "type" => "boolean",
          "description" => "Include original Greek/Hebrew text. Default: true"
        },
        "include_morphology" => %{
          "type" => "boolean",
          "description" =>
            "Include grammatical parsing for each word (and, for a passage, the word-by-word list). Default: false"
        }
      },
      "required" => ["reference"]
    }
  end

  @doc "The Markdown for the model, with `result/1`'s data for the screens (rho's tool details)."
  @impl true
  def run(args, _ctx) do
    with {:ok, result} <- result(args), do: {:ok, {:details, render(result), result}}
  end

  @typedoc """
  A looked-up passage. `label` is the heading of a passage (nil for a
  single verse), `notes` say how the request was cut, `hint_reference` is
  the verse other tools are pointed at.
  """
  @type t :: %{
          reference: String.t(),
          book: String.t(),
          book_name: String.t(),
          single: boolean(),
          label: String.t() | nil,
          notes: [String.t()],
          genre: Hermeneutics.genre() | nil,
          hint_reference: String.t(),
          include_original: boolean(),
          include_morphology: boolean(),
          verses: [Format.verse_view()]
        }

  @doc """
  The passage `args` name, as data, or `{:error, message}` for a reference
  the pack can't serve (unreadable, unknown book, chapter or verse).
  """
  @spec result(map()) :: {:ok, t()} | {:error, String.t()}
  def result(args) do
    with {:ok, found} <- find(Args.reference(args)) do
      {:ok,
       Map.merge(found, %{
         include_original: Args.flag(args, "include_original", true),
         include_morphology: Args.flag(args, "include_morphology", false)
       })}
    end
  end

  defp find(""), do: {:error, "Please provide a verse reference (e.g., 'John 3:16')."}

  defp find(reference) do
    case Reference.parse_passage(reference) do
      nil ->
        {:error,
         "Could not read '#{reference}' as a Bible reference. Supported forms: #{@forms}."}

      parsed ->
        with {:ok, found} <- DB.with_pack(:core, &fetch(&1, reference, parsed)), do: found
    end
  end

  defp fetch(conn, reference, parsed) do
    %{book: book, book_name: book_name, start_chapter: sc, end_chapter: ec} = parsed
    bounds = Verses.chapter_bounds(conn, book)

    with :ok <- check_book(bounds, book_name, reference),
         :ok <- check_chapter(bounds, book_name, sc),
         :ok <- check_chapter(bounds, book_name, ec),
         sv = parsed.start_verse || elem(bounds[sc], 0),
         ev = parsed.end_verse || elem(bounds[ec], 1),
         :ok <- check_start(bounds, book_name, sc, sv),
         :ok <- check_order({sc, sv}, {ec, ev}, reference) do
      {ev, notes} = clamp(bounds, book_name, ec, ev)

      case Verses.passage(conn, book, sc, sv, ec, ev) do
        [] -> {:error, "No verse text on file for #{reference}."}
        rows -> {:ok, shape(rows, reference, parsed, notes)}
      end
    end
  end

  defp check_book(bounds, book_name, reference) when map_size(bounds) == 0,
    do:
      {:error,
       "Unknown book '#{book_name}' in '#{reference}'. Use a book name or " <>
         "abbreviation such as 'John', 'Gen', or '1 Corinthians'."}

  defp check_book(_bounds, _book_name, _reference), do: :ok

  defp check_chapter(bounds, book_name, chapter) do
    if Map.has_key?(bounds, chapter),
      do: :ok,
      else:
        {:error,
         "#{book_name} has no chapter #{chapter} " <>
           "(chapters #{Enum.min(Map.keys(bounds))}–#{Enum.max(Map.keys(bounds))})."}
  end

  defp check_start(bounds, book_name, chapter, verse) do
    {first, last} = bounds[chapter]

    if first <= verse and verse <= last,
      do: :ok,
      else: {:error, "#{book_name} #{chapter} has no verse #{verse} (verses #{first}–#{last})."}
  end

  defp check_order(start, finish, reference) do
    if finish < start,
      do: {:error, "Invalid range '#{reference}': the end comes before the start."},
      else: :ok
  end

  defp clamp(bounds, book_name, chapter, verse) do
    {_, chapter_end} = bounds[chapter]

    if verse > chapter_end,
      do:
        {chapter_end,
         [
           "#{book_name} #{chapter} ends at verse #{chapter_end}; " <>
             "showing through #{chapter}:#{chapter_end}."
         ]},
      else: {verse, []}
  end

  # Caps the rows at @max_verses numbered verses (a verse-0 superscription
  # is shown but not counted; a verse may be several rows) and works out
  # the heading, notes and hint reference.
  defp shape(rows, reference, parsed, notes) do
    keys = rows |> Enum.map(&{&1["chapter"], &1["verse"]}) |> Enum.uniq()
    {rows, keys, notes} = cap(rows, keys, parsed.book_name, notes)
    shown_end = List.last(keys)
    single = hd(keys) == shown_end

    shown_start =
      case keys do
        [{_, 0}, next | _] -> next
        [first | _] -> first
      end

    plain = single and notes == []
    first_numbered = Enum.find(keys, shown_start, fn {_, verse} -> verse > 0 end)

    %{
      reference: reference,
      book: parsed.book,
      book_name: parsed.book_name,
      single: single,
      label: if(plain, do: nil, else: label(parsed, notes, shown_start, shown_end)),
      notes: notes,
      genre: Hermeneutics.genre(parsed.book),
      hint_reference:
        if(plain,
          do: reference,
          else: Reference.label(parsed.book_name, first_numbered, first_numbered)
        ),
      verses: Enum.map(rows, &Format.verse_view/1)
    }
  end

  defp cap(rows, keys, book_name, notes) do
    numbered = Enum.filter(keys, fn {_, verse} -> verse > 0 end)

    case Enum.split(numbered, @max_verses) do
      {_, []} ->
        {rows, keys, notes}

      {shown, [next | _]} ->
        last_shown = List.last(shown)
        rest = Reference.label(book_name, next, List.last(numbered))

        note =
          "Showing the first #{@max_verses} of #{length(numbered)} verses. " <>
            "Continue with reference='#{rest}'."

        {Enum.filter(rows, &({&1["chapter"], &1["verse"]} <= last_shown)),
         Enum.filter(keys, &(&1 <= last_shown)), notes ++ [note]}
    end
  end

  # A passage's heading: the chapter(s) when whole chapters were asked for
  # and shown in full, else the span shown.
  defp label(%{start_verse: nil, end_verse: nil} = parsed, [], _start, _end) do
    if parsed.end_chapter == parsed.start_chapter,
      do: "#{parsed.book_name} #{parsed.start_chapter}",
      else: "#{parsed.book_name} #{parsed.start_chapter}-#{parsed.end_chapter}"
  end

  defp label(parsed, _notes, shown_start, shown_end),
    do: Reference.label(parsed.book_name, shown_start, shown_end)

  @doc "The Markdown the model reads for a `result/1`."
  @spec render(t()) :: String.t()
  def render(result) do
    plain = result.single and result.notes == []
    bsb = Format.bsb_label(result.verses)

    verse_text =
      result.verses
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {view, index} ->
        Format.verse(view,
          include_original: result.include_original,
          include_morphology: result.include_morphology,
          include_words: result.single or result.include_morphology,
          heading_note: if(plain and index == 0, do: bsb, else: "")
        )
      end)

    text =
      if plain do
        verse_text
      else
        notes =
          if result.notes == [],
            do: "",
            else: Enum.map_join(result.notes, &"*#{&1}*\n") <> "\n"

        "# #{result.label}#{bsb}\n\n" <> notes <> verse_text
      end

    text <> genre(result.genre) <> cross_reference_hint(result.single, result.hint_reference)
  end

  defp genre(nil), do: ""
  defp genre(genre), do: "\n\n---\n" <> Hermeneutics.format_guidance(genre)

  defp cross_reference_hint(true, hint) do
    "\n\n---\n*Cross-references for this verse are available via " <>
      "`get_cross_references` (reference='#{hint}') — returns the strongest verses " <>
      "traditionally read alongside this one in the Treasury of Scripture " <>
      "Knowledge (TSK) topical index.*"
  end

  defp cross_reference_hint(false, hint) do
    "\n\n---\n*Cross-references are indexed per verse: call `get_cross_references` " <>
      "with one verse of this passage (e.g. reference='#{hint}') — returns the " <>
      "strongest verses traditionally read alongside it in the Treasury of " <>
      "Scripture Knowledge (TSK) topical index.*"
  end
end
