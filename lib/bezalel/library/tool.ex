defmodule Bezalel.Library.Tool do
  @moduledoc """
  A tool built in the Workshop: the shelf entry (name, the request,
  the conversation it came from, the model, when) while its code, for a
  tool a model built, is in a Dyn generation (`Bezalel.Workshop`,
  decisions/2026-10-15-workshop-on-dyn.md). `kind` picks how it renders;
  `data` is its content:

    * `"sermon_outline"`, the storyboard's sample: `"text"` (passage
      reference), `"big_idea"`, and `"moves"` (each `%{"num", "title",
      "ref", "points"}`).
    * `"dyn"`, a tool in the Dyn layer: `"module"` (`"Bezalel.Dyn.<Name>"`),
      `"tool"` (its `Rho.Tool` name), `"screen"` (its screen's registry
      name, `"<Name>.Screen"`, or nil), `"files"` (its sources in the
      generation), `"versions"` (one per approved change, oldest first:
      `"generation"`, `"description"`, `"model"`, `"session"`, or
      `"generation"` and `"removed" => true` for a removal), and the
      version the running generation has (`Bezalel.Workshop.reconcile/0`):
      `"generation"`, `"session"` (the build's rho session id) and
      `"removed"` (off the shelf), with the row's description and model.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tools" do
    field :name, :string
    field :kind, :string
    field :description, :string
    field :data, :map
    field :model, :string
    belongs_to :conversation, Bezalel.Library.Conversation
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(tool, attrs) do
    tool
    |> cast(attrs, [:name, :kind, :description, :data, :model, :conversation_id])
    |> validate_required([:name, :kind, :description, :data])
  end

  @doc "Whether the tool is on the shelf (not taken off by a removal that runs)."
  @spec shelved?(%__MODULE__{}) :: boolean()
  def shelved?(%__MODULE__{data: data}), do: not (is_map(data) and data["removed"] == true)
end
