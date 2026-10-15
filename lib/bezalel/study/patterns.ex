defmodule Bezalel.Study.Patterns do
  @moduledoc """
  The regular expressions the study tools (and the live agent's replies and
  passage cards) use, compiled on first use and kept in `:persistent_term`.
  They are not `~r` literals: a regex compiled into a module is tied to the
  OTP it was compiled under, and mob_dev builds the app on one OTP for
  phones running another.

  The study tools' sources are studybible-mcp's (`database.py`,
  `hermeneutics.py`, `tools.py`), with Python's `(?P<name>…)` written
  `(?<name>…)`.
  """

  # The reference patterns spell digits [0-9]: with "u" (needed for the
  # dashes), \d would also match other scripts' digits, which
  # String.to_integer/1 rejects.
  @sources %{
    # parse_passage_reference: "Luke 19", "Luke 19:1-3", "Luke 19:45-20:2", "Psalm 23-24".
    passage:
      {~S"^(?<book>[1-4]?\s*[A-Za-z]+(?:\s+[A-Za-z]+)*)\s*\.?\s*(?<c1>[0-9]+)(?:[:.](?<v1>[0-9]+)[a-z]?)?" <>
         ~S"(?:\s*-\s*(?:(?<c2>[0-9]+)[:.])?(?<v2>[0-9]+)[a-z]?)?$", "iu"},
    # A range separator: hyphen, the Unicode dashes, minus.
    dash: {~S"\s*[\x{2010}-\x{2015}\x{2212}-]\s*", "u"},
    # _normalize_reference: "John 3:16", "Gen. 15:6", "1 Corinthians 13:4-7".
    verse:
      {~S"^([0-9]?\s*[a-zA-Z]+(?:\s+[a-zA-Z]+)*)\.?\s*([0-9]+):([0-9]+[a-z]?)(?:-([0-9]+[a-z]?))?$",
       "iu"},
    # expand_single_chapter_reference: "Jude 3", "Philemon 4-6", "Jude".
    single_chapter:
      {~S"^\s*(?<book>(?:[1-4]\s*)?[A-Za-z]+(?:\s+[A-Za-z]+)*)\.?" <>
         ~S"(?:\s*(?<verses>[0-9]+[a-z]?(?:\s*[-\x{2010}-\x{2015}\x{2212}]\s*[0-9]+[a-z]?)?))?\s*$",
       "u"},
    whitespace: {~S"\s+", "u"},
    leading_digit: {~S"^([0-9])\s*", "u"},
    strongs: {~S"^([GH])0*(\d{1,4})([A-Z]?)$", ""},
    strongs_bare: {~S"^[GH]\d{4}$", ""},
    strongs_suffixed: {~S"^[GH]\d{4}[A-Z]$", ""},
    # A verse stored with a second numbering: 'Gen.32.1(32.2)', 'Mat.17.15[17.14]'.
    split_reference: {~S"^([^.]+)\.(\d+)\.(\d+)([(\[{])(\d+)\.(\d+)[)\]}]$", ""},
    # A Psalm superscription: 'Psa.82.0(82.1)'.
    superscription: {~S"^([^.]+)\.(\d+)\.0(?:\((\d+\.\d+)\))?$", ""},
    # get_genre_from_reference: 'Jhn.3.16', then 'John 3:16'.
    genre_code: {~S"^(\w{3})\.\d+\.\d+", "u"},
    genre_name: {~S"^(\d?\s*[a-zA-Z]+)\s*\d+:\d+", "u"},
    # Bezalel.Agent.Card: punctuation and quotes around an English word.
    word_edges: {~S"^[\p{P}\p{S}]+|[\p{P}\p{S}]+$", "u"},
    # Bezalel.Agent.Reply: a block's header, its first sentence or line.
    first_sentence: {~S"\A.+?(?:[.?!:](?=\s)|\n|\z)", "su"}
  }

  # The cache key carries a hash of the sources, so a hot-loaded version of
  # this module with a changed pattern compiles it afresh instead of reading
  # the old one out of :persistent_term.
  @version :erlang.phash2(@sources)

  @doc "The compiled pattern `name`."
  @spec get(atom()) :: Regex.t()
  def get(name) do
    key = {__MODULE__, @version, name}

    case :persistent_term.get(key, nil) do
      nil ->
        {source, options} = Map.fetch!(@sources, name)
        regex = Regex.compile!(source, options)
        :persistent_term.put(key, regex)
        regex

      regex ->
        regex
    end
  end
end
