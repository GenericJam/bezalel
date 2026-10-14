defmodule Bezalel.Workshop do
  @moduledoc """
  Builds a tool from a description and saves it to the phone. The build runs
  in steps (`steps/0`); the builder reports each one as it starts it, so the
  Workshop can show progress.

  The builder is picked by `config :bezalel, :builder`; until a model is
  connected it is `Bezalel.Workshop.Storyboard`, which builds the design's
  sermon outline for Exodus 31 and nothing else.
  """

  alias Bezalel.Library

  @steps [
    "Reading your request",
    "Laying out the sections",
    "Linking it to Exodus 31",
    "Saving it to your phone"
  ]

  @callback build(
              description :: String.t(),
              model :: map(),
              on_step :: (non_neg_integer() -> any())
            ) ::
              {:ok, %{name: String.t(), kind: String.t(), data: map(), by: String.t()}}
              | {:error, String.t()}

  @doc "Whether builds come from a real model (false for the storyboard)."
  @callback live?() :: boolean()

  @doc "The build steps, in order."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc "Whether builds come from a real model."
  @spec live?() :: boolean()
  def live?, do: impl().live?()

  @doc """
  Builds and saves a tool. `on_step.(index)` fires as each of `steps/0`
  starts. Returns the saved tool, or a message saying why it couldn't build.
  """
  @spec build(String.t(), integer() | nil, String.t(), (non_neg_integer() -> any())) ::
          {:ok, Library.Tool.t()} | {:error, String.t()}
  def build(description, conversation_id, model_id, on_step) do
    with {:ok, spec} <- impl().build(description, Bezalel.Models.get(model_id), on_step) do
      on_step.(length(@steps) - 1)
      {by, spec} = Map.pop(spec, :by)

      case Library.create_tool(
             Map.merge(spec, %{
               description: description,
               conversation_id: conversation_id,
               model: by
             })
           ) do
        {:ok, tool} -> {:ok, tool}
        {:error, _changeset} -> {:error, "The tool couldn't be saved."}
      end
    end
  end

  defp impl, do: Application.get_env(:bezalel, :builder, Bezalel.Workshop.Storyboard)
end

defmodule Bezalel.Workshop.Storyboard do
  @moduledoc """
  The design's tool build: a sermon outline for Exodus 31:1–11 (big idea and
  three movements). It accepts a request for a sermon outline whose only
  passage, if any, is Exodus 31; anything else needs a connected model, and
  says so rather than handing back the Exodus outline.
  """
  @behaviour Bezalel.Workshop

  # Other books, by name and common abbreviation, so "Sermon outline on Ruth"
  # or "... for Jn 3" isn't answered with Exodus. Any chapter number other
  # than Exodus 31's is caught separately.
  @other_books ~w(genesis gen leviticus lev numbers num deuteronomy deut dt joshua josh
                  judges judg ruth samuel sam kings kgs chronicles chr ezra nehemiah neh
                  esther esth job psalm psalms ps prov proverbs ecclesiastes eccl song
                  isaiah isa jeremiah jer lamentations lam ezekiel ezek daniel dan hosea hos
                  joel amos obadiah obad jonah micah mic nahum nah habakkuk hab zephaniah zeph
                  haggai hag zechariah zech malachi mal matthew matt mt mark mk luke lk john jn
                  acts romans rom corinthians cor galatians gal ephesians eph philippians phil
                  colossians col thessalonians thess timothy tim titus philemon hebrews heb
                  james jas peter pet jude revelation rev)
  @impl true
  def live?, do: false

  @impl true
  def build(description, _model, on_step) do
    on_step.(0)

    if exodus_outline?(description) do
      on_step.(1)
      on_step.(2)
      {:ok, %{name: "Sermon Outline", kind: "sermon_outline", data: outline(), by: "storyboard"}}
    else
      {:error,
       "Without a connected model the Workshop can only build the design’s sermon outline for " <>
         "Exodus 31. Ask for that, or try again once a model is connected."}
    end
  end

  defp exodus_outline?(description) do
    low = String.downcase(description)
    # Take out the one passage it knows (Exodus 31, Ex 31:2–3, ...); any
    # number left over is some other passage.
    rest =
      Regex.replace(Regex.compile!("\\bex(odus)?\\.?\\s*31(:\\d+([–-]\\d+)?)?", "u"), low, " ")

    words = String.split(rest, Regex.compile!("[^\\p{L}\\p{N}]+", "u"), trim: true)

    "sermon" in words and "outline" in words and
      not Enum.any?(words, &(&1 in @other_books or digit?(&1)))
  end

  defp digit?(word), do: String.contains?(word, ~w(0 1 2 3 4 5 6 7 8 9))

  defp outline do
    %{
      "text" => "Exodus 31:1–11",
      "big_idea" => "God fills ordinary hands for holy work.",
      "moves" => [
        %{
          "num" => "I",
          "title" => "Called by name",
          "ref" => "v. 2",
          "points" => [
            "God names an artisan, not a priest or a king.",
            "Your work is a calling before it’s a career."
          ]
        },
        %{
          "num" => "II",
          "title" => "Filled with the Spirit",
          "ref" => "v. 3–5",
          "points" => [
            "The first Spirit-filling in Scripture is for craftsmanship.",
            "Skill (ḥokmâ) is the same word as wisdom."
          ]
        },
        %{
          "num" => "III",
          "title" => "Given to the work",
          "ref" => "v. 6–11",
          "points" => [
            "Oholiab is given to work alongside him; no one builds alone.",
            "Close: the lampstand they made, Ex 37:17."
          ]
        }
      ]
    }
  end
end
