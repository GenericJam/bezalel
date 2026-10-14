defmodule Bezalel.Repo.Migrations.MessagePositions do
  use Ecto.Migration

  # Positions are handed out from a per-conversation counter and never reused,
  # so a deleted message's slot stays its own and Undo can't collide with a
  # message added in the meantime. The unique index holds that.
  def up do
    alter table(:conversations) do
      add :next_position, :integer, null: false, default: 1
    end

    flush()

    # Before the counter, max+1 could hand a deleted last message's slot to
    # the next one; renumber 1..n so the unique index holds.
    execute("""
    UPDATE messages SET position = (
      SELECT COUNT(*) FROM messages m2
      WHERE m2.conversation_id = messages.conversation_id
        AND (m2.position < messages.position OR (m2.position = messages.position AND m2.id <= messages.id))
    )
    """)

    execute("""
    UPDATE conversations SET next_position =
      COALESCE((SELECT MAX(position) FROM messages WHERE messages.conversation_id = conversations.id), 0) + 1
    """)

    drop index(:messages, [:conversation_id, :position])
    create unique_index(:messages, [:conversation_id, :position])
  end

  def down do
    drop index(:messages, [:conversation_id, :position])
    create index(:messages, [:conversation_id, :position])

    alter table(:conversations) do
      remove :next_position
    end
  end
end
