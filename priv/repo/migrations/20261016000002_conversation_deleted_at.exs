defmodule Bezalel.Repo.Migrations.ConversationDeletedAt do
  use Ecto.Migration

  # A deleted conversation is off the shelf at once and purged, with its
  # session and the files that go with it, once its Undo is no longer
  # offered (Bezalel.Library.delete_conversation/1). Until then it's kept,
  # marked with when it was deleted.
  def change do
    alter table(:conversations) do
      add :deleted_at, :utc_datetime_usec
    end
  end
end
