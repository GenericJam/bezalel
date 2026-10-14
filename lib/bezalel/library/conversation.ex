defmodule Bezalel.Library.Conversation do
  @moduledoc "One study conversation: a week's sermon prep, a word study, ..."
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    field(:name, :string)
    field(:kicker, :string)
    field(:kind, :string)
    has_many(:messages, Bezalel.Library.Message)
    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:name, :kicker, :kind])
    |> validate_required([:name, :kicker, :kind])
  end
end
