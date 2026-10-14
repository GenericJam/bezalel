defmodule Bezalel.Library.Tool do
  @moduledoc """
  A tool built in the Workshop. `kind` picks how it renders; `data` is its
  content. A `"sermon_outline"` holds `"text"` (passage reference),
  `"big_idea"`, and `"moves"` (each `%{"num", "title", "ref", "points"}`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "tools" do
    field(:name, :string)
    field(:kind, :string)
    field(:description, :string)
    field(:data, :map)
    field(:model, :string)
    belongs_to(:conversation, Bezalel.Library.Conversation)
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(tool, attrs) do
    tool
    |> cast(attrs, [:name, :kind, :description, :data, :model, :conversation_id])
    |> validate_required([:name, :kind, :description, :data])
  end
end
