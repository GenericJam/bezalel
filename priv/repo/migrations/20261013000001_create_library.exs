defmodule Bezalel.Repo.Migrations.CreateLibrary do
  use Ecto.Migration

  def change do
    # One study conversation (a week's sermon prep, a word study, ...).
    create table(:conversations) do
      add :name, :text, null: false
      # Uppercase label over the chat, e.g. "SERMON PREP · EXODUS 31".
      add :kicker, :text, null: false
      # "Sermon prep", "Word study", "Study": shown in the shelf.
      add :kind, :text, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      # Order inside the conversation; kept on delete so an undo restores the slot.
      add :position, :integer, null: false
      add :role, :text, null: false
      add :text, :text
      # Agent output: [%{"id", "type", "first", "rest"}] (THINKING / TOOL CALL / SUMMARY).
      add :blocks, {:array, :map}, null: false, default: "[]"
      # A cited passage the reply shows inline (key into Bezalel.Scripture).
      add :passage, :text
      # A requested drawing, e.g. "lampstand" (shown when the model can draw).
      add :image, :text
      # The model that answered (id from Bezalel.Models).
      add :model, :text
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:conversation_id, :position])

    # A tool built in the Workshop. `data` holds the tool's own content.
    create table(:tools) do
      add :name, :text, null: false
      add :kind, :text, null: false
      add :description, :text, null: false
      add :data, :map, null: false
      add :conversation_id, references(:conversations, on_delete: :nilify_all)
      add :model, :text
      timestamps(type: :utc_datetime)
    end
  end
end
