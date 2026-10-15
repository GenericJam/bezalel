defmodule Bezalel.Library.Conversation do
  @moduledoc """
  One study conversation on the shelf: a week's sermon prep, a word study, ...
  Its transcript is its rho session (`session_id`, in the file
  `session_file` under `Rho.Session.dir/0`; both nil until it's first
  written); `message_count` is what the shelf shows.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "conversations" do
    field :name, :string
    field :kicker, :string
    field :kind, :string
    field :session_id, :string
    field :session_file, :string
    field :message_count, :integer, default: 0
    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:name, :kicker, :kind])
    |> validate_required([:name, :kicker, :kind])
  end
end
