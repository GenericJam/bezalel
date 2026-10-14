defmodule Bezalel.Models do
  @moduledoc """
  The models the user can pick from (the design's model sheet), grouped by
  provider. `image: true` marks the ones that can draw.
  """

  @models [
    %{
      id: "sonnet",
      group: "ANTHROPIC",
      name: "Claude Sonnet",
      note: "Careful with sources",
      dot: 0xFFC67139,
      tags: []
    },
    %{
      id: "haiku",
      group: "ANTHROPIC",
      name: "Claude Haiku",
      note: "Fast, light",
      dot: 0xFFC67139,
      tags: []
    },
    %{
      id: "gpt",
      group: "OPENAI",
      name: "GPT",
      note: "General purpose",
      dot: 0xFF5E8C6A,
      tags: ["IMAGES"],
      image: true
    },
    %{id: "grok", group: "XAI", name: "Grok", note: "Conversational", dot: 0xFF8A8A8A, tags: []},
    %{
      id: "gemini",
      group: "GOOGLE",
      name: "Gemini Pro",
      note: "Long context",
      dot: 0xFF4A6FA5,
      tags: ["IMAGES"],
      image: true
    },
    %{
      id: "flash",
      group: "GOOGLE",
      name: "Gemini Flash",
      note: "Free tier",
      dot: 0xFF4A6FA5,
      tags: ["FREE"]
    },
    %{
      id: "llama",
      group: "OTHER",
      name: "Llama (open)",
      note: "Free hosted model",
      dot: 0xFF7A8A5E,
      tags: ["FREE"]
    },
    %{
      id: "key",
      group: "OTHER",
      name: "Your API key",
      note: "Any compatible endpoint",
      dot: 0xFF9E2B25,
      tags: ["BYO"]
    }
  ]

  @default "sonnet"

  @doc "The default model id."
  @spec default() :: String.t()
  def default, do: @default

  @doc "Every model."
  @spec all() :: [map()]
  def all, do: @models

  @doc "A model by id; unknown ids fall back to the default."
  @spec get(String.t() | nil) :: map()
  def get(id), do: Enum.find(@models, &(&1.id == id)) || Enum.find(@models, &(&1.id == @default))

  @doc "Models grouped by provider, in catalogue order: `[{group, [model]}]`."
  @spec groups() :: [{String.t(), [map()]}]
  def groups do
    @models
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn [first | _] = models -> {first.group, models} end)
  end

  @doc """
  Who a message or tool is attributed to: the model's name, or "Scripted
  reply" for the design's storyboard.
  """
  @spec attribution(String.t() | nil) :: String.t()
  def attribution("storyboard"), do: "Scripted reply"
  def attribution(id), do: get(id).name

  @doc "Whether the model can draw images."
  @spec draws?(map()) :: boolean()
  def draws?(model), do: Map.get(model, :image, false)
end
