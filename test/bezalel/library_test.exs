defmodule Bezalel.LibraryTest do
  use ExUnit.Case, async: false

  alias Bezalel.Library
  alias Bezalel.Library.{Conversation, Message, Tool}
  alias Bezalel.Repo

  setup do
    for schema <- [Message, Tool, Conversation], do: Repo.delete_all(schema)
    :ok
  end

  defp conversation!(name \\ "Romans 12") do
    {:ok, c} =
      Library.create_conversation(%{name: name, kicker: "SERMON PREP", kind: "Sermon prep"})

    c
  end

  test "an undone delete puts the message back in its place, with its id" do
    c = conversation!()
    {:ok, first} = Library.add_message(c, %{role: :user, text: "one"})

    {:ok, middle} =
      Library.add_message(c, %{role: :agent, blocks: [%{"id" => "sum"}], model: "haiku"})

    {:ok, last} = Library.add_message(c, %{role: :user, text: "three"})

    {:ok, deleted} = Library.delete_message(middle.id)
    assert Enum.map(Library.messages(c.id), & &1.id) == [first.id, last.id]

    {:ok, _} = Library.restore_message(deleted)
    restored = Library.messages(c.id)
    assert Enum.map(restored, & &1.id) == [first.id, middle.id, last.id]
    assert Enum.at(restored, 1).blocks == [%{"id" => "sum"}]
  end

  test "a message added after a delete never takes the deleted one's slot" do
    c = conversation!()
    {:ok, _} = Library.add_message(c, %{role: :user, text: "one"})
    {:ok, two} = Library.add_message(c, %{role: :user, text: "two"})
    {:ok, three} = Library.add_message(c, %{role: :user, text: "three"})
    {:ok, deleted} = Library.delete_message(two.id)
    {:ok, four} = Library.add_message(c, %{role: :user, text: "four"})

    {:ok, _} = Library.restore_message(deleted)
    assert Library.messages(c.id) |> Enum.map(& &1.text) == ["one", "two", "three", "four"]
    assert four.position > three.position
  end

  test "a user message needs text" do
    c = conversation!()
    assert {:error, changeset} = Library.add_message(c, %{role: :user, text: nil})
    assert "can't be blank" in errors_on(changeset).text
  end

  test "the shelf lists the most recently active conversation first, with message counts" do
    older = conversation!("Psalm 119")
    newer = conversation!("Ruth")
    {:ok, _} = Library.add_message(newer, %{role: :user, text: "ḥesed?"})
    # Activity in the older one moves it to the top.
    Repo.update_all(Conversation, set: [updated_at: ~U[2026-01-01 00:00:00Z]])
    {:ok, _} = Library.add_message(older, %{role: :user, text: "lamp"})
    {:ok, _} = Library.add_message(older, %{role: :user, text: "path"})

    assert [
             %{conversation: %{name: "Psalm 119"}, message_count: 2},
             %{conversation: %{name: "Ruth"}, message_count: 1}
           ] =
             Library.list_conversations()

    assert Library.latest_conversation().id == older.id
  end

  test "the first-run study is stored once, then the latest conversation is opened" do
    seeded = Library.seed!()
    assert seeded.name == "Exodus 31 · Bezalel"

    assert [
             %{role: :user},
             %{role: :agent, passage: "exodus-31-2-3"},
             %{role: :user},
             %{role: :agent, image: "lampstand"}
           ] =
             Library.messages(seeded.id)

    assert Library.seed!().id == seeded.id
    assert Library.conversation_count() == 1
  end

  test "deleting a conversation's last trace: an unknown message id is reported, not raised" do
    assert Library.delete_message(-1) == {:error, :not_found}
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
