defmodule Bezalel.Workshop.Storyboard do
  @moduledoc """
  The design's tool build, used without a model (`Bezalel.Workshop`):
  whatever is described, it builds the design's sample, a sermon outline
  for Exodus 31:1–11 (big idea and three movements). The Workshop says so
  before the build; building what was described needs a connected model.
  """

  @doc "The sample's shelf entry; `on_step.(i)` fires for the first three steps."
  @spec build(String.t(), map(), (non_neg_integer() -> any())) :: {:ok, map()}
  def build(_description, _model, on_step) do
    on_step.(0)
    on_step.(1)
    on_step.(2)
    {:ok, %{name: "Sermon Outline", kind: "sermon_outline", data: outline(), by: "storyboard"}}
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
