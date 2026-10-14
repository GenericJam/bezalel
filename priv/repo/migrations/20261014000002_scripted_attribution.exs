defmodule Bezalel.Repo.Migrations.ScriptedAttribution do
  use Ecto.Migration

  # Every reply and tool stored so far came from the storyboard (no model was
  # ever connected), but was labelled with the model chosen at the time.
  # Timestamps moved to microseconds; old second-precision strings sort after
  # same-second fractional ones, so pad them to the new format.
  @stamps [
    conversations: [:inserted_at, :updated_at],
    messages: [:inserted_at],
    tools: [:inserted_at, :updated_at]
  ]

  def up do
    execute("UPDATE messages SET model = 'storyboard' WHERE role = 'agent'")
    execute("UPDATE tools SET model = 'storyboard'")

    for {table, columns} <- @stamps, column <- columns do
      execute("""
      UPDATE #{table} SET #{column} =
        CASE WHEN #{column} LIKE '%Z'
             THEN substr(#{column}, 1, length(#{column}) - 1) || '.000000Z'
             ELSE #{column} || '.000000' END
      WHERE #{column} NOT LIKE '%.%'
      """)
    end
  end

  # Which model each row named before is gone; nothing to restore.
  def down, do: :ok
end
