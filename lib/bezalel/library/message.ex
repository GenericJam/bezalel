defmodule Bezalel.Library.Message do
  @moduledoc """
  A message in a conversation. A user message has `text`. An agent message has
  `blocks` (each `%{"id", "type", "first", "rest"}`: THINKING, TOOL CALL,
  SUMMARY), and optionally a cited `passage` (a `Bezalel.Scripture` key) or a
  requested `image`, plus the `model` that answered.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "messages" do
    belongs_to(:conversation, Bezalel.Library.Conversation)
    field(:position, :integer)
    field(:role, Ecto.Enum, values: [:user, :agent])
    field(:text, :string)
    field(:blocks, {:array, :map}, default: [])
    field(:passage, :string)
    field(:image, :string)
    field(:model, :string)
    timestamps(type: :utc_datetime, updated_at: false)
  end

  @fields [:conversation_id, :position, :role, :text, :blocks, :passage, :image, :model]

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields)
    |> validate_required([:conversation_id, :position, :role])
    |> validate_role_content()
  end

  defp validate_role_content(changeset) do
    case get_field(changeset, :role) do
      :user -> validate_required(changeset, [:text])
      _ -> changeset
    end
  end
end
