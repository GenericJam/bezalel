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
  three movements). It accepts a description that asks for a sermon outline
  and names no book but Exodus; anything else needs a connected model, and
  says so rather than handing back the Exodus outline.
  """
  @behaviour Bezalel.Workshop

  # Every other book, so "Romans 12 sermon outline" isn't answered with Exodus.
  @other_books ~w(genesis leviticus numbers deuteronomy joshua judges ruth samuel kings
                  chronicles ezra nehemiah esther job psalm psalms proverbs ecclesiastes song
                  isaiah jeremiah lamentations ezekiel daniel hosea joel amos obadiah jonah micah
                  nahum habakkuk zephaniah haggai zechariah malachi matthew mark luke john acts
                  romans corinthians galatians ephesians philippians colossians thessalonians
                  timothy titus philemon hebrews james peter jude revelation)

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
    words =
      description
      |> String.downcase()
      |> String.split(Regex.compile!("[^\\p{L}]+", "u"), trim: true)

    "sermon" in words and "outline" in words and not Enum.any?(words, &(&1 in @other_books))
  end

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
