defmodule Bezalel.Scripture do
  @moduledoc """
  The passages and lexicon entries the app can show. For now this is the
  Exodus 31 material from the Core Screens v2 design: the BSB text of
  Exodus 31:2–3 and four Hebrew words from it. A full Bible text and lexicon
  replace this module's data, not its interface.
  """

  @passages %{
    "exodus-31-2-3" => %{
      ref: "Exodus 31:2–3",
      version: "BSB",
      text:
        "See, I have called by name Bezalel son of Uri, the son of Hur, of the tribe of Judah. " <>
          "And I have filled him with the Spirit of God, with skill, ability, and knowledge " <>
          "in all kinds of craftsmanship.",
      # English word (lowercased, punctuation stripped) → lexicon key.
      words: %{
        "called" => "called",
        "filled" => "filled",
        "spirit" => "spirit",
        "skill" => "skill"
      }
    }
  }

  @words %{
    "called" => %{
      heb: "קָרָאתִי",
      translit: "qārāʾ",
      strong: "H7121",
      count: 739,
      gloss: "to call, to summon by name, to proclaim",
      note:
        "Being “called by name” is the language of commissioning. Isaiah uses the same phrase for Israel and for Cyrus.",
      refs: ["Isa 43:1", "Isa 45:3", "Ex 35:30"],
      phrase: {"רְאֵה ", " בְשֵׁם בְּצַלְאֵל"}
    },
    "filled" => %{
      heb: "וָאֲמַלֵּא",
      translit: "mālēʾ",
      strong: "H4390",
      count: 252,
      gloss: "to fill, to be full; to consecrate",
      note:
        "The same root is used for “filling the hand”, the phrase for ordaining priests. Bezalel’s hands are ordained for the work.",
      refs: ["Ex 28:41", "Ex 35:31", "Deut 34:9", "Acts 2:4"],
      phrase: {"", " אֹתוֹ רוּחַ אֱלֹהִים"}
    },
    "spirit" => %{
      heb: "רוּחַ",
      translit: "rûaḥ",
      strong: "H7307",
      count: 378,
      gloss: "wind, breath, spirit",
      note:
        "The same breath that hovers over the waters in Genesis 1:2 now rests on a craftsman.",
      refs: ["Gen 1:2", "Num 11:25", "Isa 11:2", "Acts 2:3"],
      phrase: {"וָאֲמַלֵּא אֹתוֹ ", " אֱלֹהִים"}
    },
    "skill" => %{
      heb: "בְּחָכְמָה",
      translit: "ḥokmâ",
      strong: "H2451",
      count: 149,
      gloss: "wisdom, skill, technical expertise",
      note:
        "Hebrew “wisdom” includes skill with your hands. The fear of the Lord in Proverbs and the work at the workbench share one word.",
      refs: ["Ex 28:3", "1 Kgs 7:14", "Prov 9:10"],
      phrase: {"רוּחַ אֱלֹהִים ", " וּבִתְבוּנָה"}
    }
  }

  @doc "A passage by key, or nil."
  @spec passage(String.t() | nil) :: map() | nil
  def passage(key), do: Map.get(@passages, key)

  @doc "A lexicon entry by key, or nil."
  @spec word(String.t() | nil) :: map() | nil
  def word(key), do: Map.get(@words, key)

  @doc "Every lexicon key."
  @spec word_keys() :: [String.t()]
  def word_keys, do: Map.keys(@words)

  @doc """
  The passage text as `{word, lexicon_key_or_nil}` tokens in order, for
  rendering tappable words. Punctuation stays attached to its word.
  """
  @spec tokens(map()) :: [{String.t(), String.t() | nil}]
  def tokens(%{text: text, words: words}) do
    text
    |> String.split(" ", trim: true)
    |> Enum.map(fn token ->
      bare = token |> String.downcase() |> String.trim(",.;:!?“”\"'")
      {token, Map.get(words, bare)}
    end)
  end
end
