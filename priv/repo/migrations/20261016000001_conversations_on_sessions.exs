defmodule Bezalel.Repo.Migrations.ConversationsOnSessions do
  use Ecto.Migration

  # A conversation's transcript moves into its rho session (JSONL, in
  # Rho.Session.dir/0); the conversations table keeps the shelf: the
  # session's id and file, and the message count it shows. Every stored
  # conversation is written into a session (Bezalel.Library.Legacy), then
  # the messages table and the position counter go.
  def up do
    alter table(:conversations) do
      add :session_id, :text
      # The session's file name in Rho.Session.dir/0 (the data dir's path
      # changes between installs on iOS, so it isn't stored).
      add :session_file, :text
      add :message_count, :integer, null: false, default: 0
    end

    flush()

    execute(fn -> Bezalel.Library.Legacy.move!(repo()) end)

    drop table(:messages)

    alter table(:conversations) do
      remove :next_position
    end
  end

  def down do
    raise Ecto.MigrationError,
          "ConversationsOnSessions is irreversible: the messages live in the sessions now"
  end
end
