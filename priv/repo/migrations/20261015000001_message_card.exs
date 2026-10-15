defmodule Bezalel.Repo.Migrations.MessageCard do
  use Ecto.Migration

  # A live reply's passage card (Bezalel.Agent.Card), built from its tool
  # results; scripted replies keep naming a Bezalel.Scripture passage.
  def change do
    alter table(:messages) do
      add :card, :map
    end
  end
end
