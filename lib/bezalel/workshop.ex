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

  @callback build(description :: String.t(), on_step :: (non_neg_integer() -> any())) ::
              {:ok, %{name: String.t(), kind: String.t(), data: map()}} | {:error, String.t()}

  @doc "The build steps, in order."
  @spec steps() :: [String.t()]
  def steps, do: @steps

  @doc """
  Builds and saves a tool. `on_step.(index)` fires as each of `steps/0`
  starts. Returns the saved tool, or a message saying why it couldn't build.
  """
  @spec build(String.t(), integer() | nil, String.t(), (non_neg_integer() -> any())) ::
          {:ok, Library.Tool.t()} | {:error, String.t()}
  def build(description, conversation_id, model_id, on_step) do
    with {:ok, spec} <- impl().build(description, on_step) do
      on_step.(length(@steps) - 1)

      case Library.create_tool(
             Map.merge(spec, %{
               description: description,
               conversation_id: conversation_id,
               model: model_id
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
  three movements). Any other kind of tool needs a connected model.
  """
  @behaviour Bezalel.Workshop

  @impl true
  def build(description, on_step) do
    on_step.(0)

    if String.contains?(String.downcase(description), ["sermon", "outline"]) do
      on_step.(1)
      on_step.(2)
      {:ok, %{name: "Sermon Outline", kind: "sermon_outline", data: outline()}}
    else
      {:error,
       "Without a connected model the Workshop can only build the sermon outline. " <>
         "Describe a sermon outline, or try again once a model is connected."}
    end
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
