defmodule Bezalel.Library.Legacy do
  @moduledoc """
  The one-time move of conversations from the old messages table into rho
  sessions (migration `ConversationsOnSessions`). Each conversation with
  messages gets a session holding them in order: a user message as a user
  entry, a reply as the assistant entry `Bezalel.Library.Transcript.reply/1`
  writes (its blocks, passage, card, drawing and model as the chat showed
  them; its SUMMARY for the model). The shelf row records the session and
  the message count.

  Reads and writes the tables with plain SQL on the migration's repo (no
  schemas: these tables are about to change). Idempotent: a conversation
  that already has a session is left alone, so running it again moves
  only what's left. A conversation's session file is named after it
  (`legacy-<id>.jsonl`), and its first entry writes the file over any
  there: when a migration fails partway (its transaction rolls the shelf
  back, or the app is killed), the run after it rewrites the files the
  failed one left instead of leaving them behind.
  """

  alias Bezalel.Library.Transcript
  alias Rho.Session

  @doc "Moves every conversation's messages into a session, on `repo`."
  @spec move!(module()) :: :ok
  def move!(repo) do
    %{rows: conversations} =
      repo.query!("SELECT id FROM conversations WHERE session_file IS NULL ORDER BY id")

    for [id] <- conversations, do: move_one!(repo, id)
    :ok
  end

  defp move_one!(repo, id) do
    %{rows: rows} =
      repo.query!(
        """
        SELECT role, text, blocks, passage, card, image, model, inserted_at
        FROM messages WHERE conversation_id = ?1 ORDER BY position, id
        """,
        [id]
      )

    case Enum.map(rows, &entry/1) do
      [] ->
        :ok

      entries ->
        model = Enum.find_value(Enum.reverse(rows), &live_model/1) || Bezalel.Models.default()
        session = Session.new(Session.dir(), model, Rho.Config.data_dir())
        session = %{session | path: Path.join(Session.dir(), "legacy-#{id}.jsonl")}
        _session = Enum.reduce(entries, session, &elem(Session.append(&2, &1), 0))

        repo.query!(
          "UPDATE conversations SET session_id = ?1, session_file = ?2, message_count = ?3 WHERE id = ?4",
          [session.id, Path.basename(session.path), length(entries), id]
        )
    end
  end

  defp entry(["user", text | _]), do: Transcript.user(text || "")

  defp entry(["agent", _text, blocks, passage, card, image, model, inserted_at]) do
    Transcript.reply(%{
      blocks: blocks |> decode() |> List.wrap() |> Enum.map(&decode/1),
      passage: passage,
      card: decode(card),
      image: image,
      model: model || "storyboard",
      at: at(inserted_at)
    })
  end

  # A reply a model wrote (not the storyboard's): the session starts on it.
  defp live_model(["agent", _, _, _, _, _, model, _]) when model not in [nil, "storyboard"],
    do: model

  defp live_model(_row), do: nil

  # ecto_sqlite3 kept `{:array, :map}` as a JSON array of JSON strings (one
  # per map), and `:map` as a JSON object.
  defp decode(nil), do: nil
  defp decode(json) when is_binary(json), do: Jason.decode!(json)
  defp decode(value), do: value

  defp at(stamp) when is_binary(stamp) do
    case DateTime.from_iso8601(if String.ends_with?(stamp, "Z"), do: stamp, else: stamp <> "Z") do
      {:ok, at, _} -> at
      _ -> nil
    end
  end

  defp at(_), do: nil
end
