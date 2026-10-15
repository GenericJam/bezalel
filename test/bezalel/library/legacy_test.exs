defmodule Bezalel.Library.LegacyTest do
  # Conversations stored before sessions (the messages table) move into
  # rho sessions on upgrade: on a database of their own, migrated up to the
  # last version with the messages table, filled as the old app left it.
  use ExUnit.Case, async: false

  alias Bezalel.Agent.Storyboard
  alias Bezalel.{Library, Repo}
  alias Bezalel.Library.Legacy
  alias Ecto.Adapters.SQLite3

  @before_sessions 20_261_015_000_001
  @migrations Application.app_dir(:bezalel, "priv/repo/migrations")

  setup do
    db = Path.join(System.tmp_dir!(), "bezalel_legacy_#{System.unique_integer([:positive])}.db")
    {:ok, repo} = Repo.start_link(name: nil, database: db)
    Repo.put_dynamic_repo(repo)

    Ecto.Migrator.run(Repo, @migrations, :up,
      to: @before_sessions,
      dynamic_repo: repo,
      log: false
    )

    on_exit(fn ->
      File.rm(db)
    end)

    :ok
  end

  defp insert_conversation!(name, updated_at) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO conversations (name, kicker, kind, next_position, inserted_at, updated_at)
        VALUES (?1, 'K', 'Study', 1, '2026-10-01T10:00:00.000000Z', ?2)
        RETURNING id
        """,
        [name, updated_at]
      )

    id
  end

  # Columns as the old Message schema's types stored them (ecto_sqlite3's
  # dumpers: `{:array, :map}` is a JSON array of JSON strings).
  defp insert_message!(conversation_id, position, fields) do
    {:ok, blocks} = Ecto.Type.adapter_dump(SQLite3, {:array, :map}, fields[:blocks] || [])
    {:ok, card} = Ecto.Type.adapter_dump(SQLite3, :map, fields[:card])

    Repo.query!(
      """
      INSERT INTO messages (conversation_id, position, role, text, blocks, passage, card, image, model, inserted_at)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, '2026-10-01T10:00:00.000000Z')
      """,
      [
        conversation_id,
        position,
        fields[:role],
        fields[:text],
        blocks,
        fields[:passage],
        card,
        fields[:image],
        fields[:model]
      ]
    )
  end

  # The seeded Exodus 31 study as the first app stored it, a live reply
  # with a passage card, and an empty conversation.
  defp old_library! do
    exodus = insert_conversation!("Exodus 31 · Bezalel", "2026-10-03T10:00:00.000000Z")
    insert_message!(exodus, 1, role: "user", text: "Help me prepare a sermon on Bezalel")

    insert_message!(exodus, 2,
      role: "agent",
      model: "storyboard",
      passage: "exodus-31-2-3",
      blocks: Storyboard.opening_blocks()
    )

    insert_message!(exodus, 3, role: "user", text: "Show me the lampstand he made.")
    insert_message!(exodus, 4, role: "agent", model: "storyboard", image: "lampstand")

    live = insert_conversation!("Ruth", "2026-10-02T10:00:00.000000Z")
    insert_message!(live, 1, role: "user", text: "ḥesed?")

    insert_message!(live, 3,
      role: "agent",
      model: "anthropic:claude-sonnet-4-5",
      card: %{"title" => "Ruth 1:8", "verses" => []},
      blocks: [%{"id" => "sum", "type" => "SUMMARY", "first" => "Loyal love.", "rest" => ""}]
    )

    empty = insert_conversation!("New study", "2026-10-01T10:00:00.000000Z")
    {exodus, live, empty}
  end

  test "an upgrade moves every conversation into a session, with what the chat showed" do
    {exodus, live, empty} = old_library!()

    Ecto.Migrator.run(Repo, @migrations, :up,
      all: true,
      dynamic_repo: Repo.get_dynamic_repo(),
      log: false
    )

    assert %{rows: []} =
             Repo.query!(
               "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'messages'"
             )

    assert [
             %{role: :user, text: "Help me prepare a sermon on Bezalel"},
             %{role: :agent, passage: "exodus-31-2-3", model: "storyboard", blocks: blocks},
             %{role: :user, text: "Show me the lampstand he made."},
             %{role: :agent, image: "lampstand", model: "storyboard"}
           ] = Library.messages(exodus)

    assert blocks == Storyboard.opening_blocks()

    assert [%{role: :user, text: "ḥesed?"}, reply] = Library.messages(live)
    assert reply.card == %{"title" => "Ruth 1:8", "verses" => []}
    assert reply.model == "anthropic:claude-sonnet-4-5"

    assert Library.messages(empty) == []
    assert Library.get_conversation(empty).session_file == nil

    # The shelf keeps its order and shows the counts.
    assert [{"Exodus 31 · Bezalel", 4}, {"Ruth", 2}, {"New study", 0}] =
             Enum.map(Library.list_conversations(), &{&1.conversation.name, &1.message_count})

    # The model reads each reply's SUMMARY, as before.
    {:ok, _session, entries} = Library.session(live, "anthropic:claude-sonnet-4-5")

    assert ["ḥesed?", "Loyal love."] =
             for(m <- Rho.Session.context(entries), do: hd(m.content).text)
  end

  test "moving is idempotent: a conversation that has a session is left alone" do
    {exodus, _live, _empty} = old_library!()

    Repo.query!("ALTER TABLE conversations ADD COLUMN session_id TEXT")
    Repo.query!("ALTER TABLE conversations ADD COLUMN session_file TEXT")
    Repo.query!("ALTER TABLE conversations ADD COLUMN message_count INTEGER NOT NULL DEFAULT 0")

    :ok = Legacy.move!(Repo)
    %{rows: first} = Repo.query!("SELECT id, session_file FROM conversations ORDER BY id")
    :ok = Legacy.move!(Repo)
    %{rows: second} = Repo.query!("SELECT id, session_file FROM conversations ORDER BY id")

    assert first == second
    assert [[^exodus, file] | _] = first
    path = Path.join(Rho.Session.dir(), file)
    # One header, the model, four messages: written once.
    assert path |> File.read!() |> String.split("\n", trim: true) |> length() == 6
  end

  test "a move that failed partway leaves no session file behind once it runs again" do
    # Text no other test's session holds: the sessions directory is shared.
    tag = "orphan-#{System.unique_integer([:positive])}"
    first = insert_conversation!("First", "2026-10-02T10:00:00.000000Z")
    insert_message!(first, 1, role: "user", text: "#{tag} one")
    broken = insert_conversation!("Broken", "2026-10-01T10:00:00.000000Z")
    insert_message!(broken, 1, role: "user", text: "#{tag} two")
    insert_message!(broken, 2, role: "agent", blocks: [%{"id" => "sum"}])
    Repo.query!("UPDATE messages SET blocks = 'not json' WHERE role = 'agent'")

    migrate = fn ->
      Ecto.Migrator.run(Repo, @migrations, :up,
        all: true,
        dynamic_repo: Repo.get_dynamic_repo(),
        log: false
      )
    end

    holding_tag = fn ->
      for path <- Path.wildcard(Path.join(Rho.Session.dir(), "*.jsonl")),
          File.read!(path) =~ tag,
          do: Path.basename(path)
    end

    # The first conversation's session was written before the second
    # failed; the shelf went back to how it was.
    assert_raise Jason.DecodeError, migrate
    assert [_written] = holding_tag.()

    {:ok, blocks} = Ecto.Type.adapter_dump(SQLite3, {:array, :map}, [%{"id" => "sum"}])
    Repo.query!("UPDATE messages SET blocks = ?1 WHERE role = 'agent'", [blocks])
    migrate.()

    shelf = for id <- [first, broken], do: Library.get_conversation(id).session_file
    assert Enum.sort(holding_tag.()) == Enum.sort(shelf)
    assert [%{text: one}] = Library.messages(first)
    assert [%{text: two}, %{role: :agent}] = Library.messages(broken)
    assert {one, two} == {"#{tag} one", "#{tag} two"}
  end
end
