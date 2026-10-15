defmodule Bezalel.Library do
  @moduledoc """
  What the app keeps on the phone: the shelf of conversations, each one's
  transcript, and the tools built in the Workshop.

  A conversation's transcript is its rho session (`Rho.Session`, a JSONL
  file in `Rho.Session.dir/0`); the conversations table is the shelf
  (name, kind, kicker, the session's id and file, the message count).
  The live agent's loop writes the session while it answers
  (`Bezalel.Agent.Live` resumes it); everything else (scripted replies,
  Delete and Undo as branch moves, a question taken back to ask again) is
  written here, only while the conversation has no loop: the caller
  releases it first, since a loop keeps its own place in the file. How
  the messages are read off the session and what the moves are:
  `Bezalel.Library.Transcript`.
  """
  import Ecto.Query

  alias Bezalel.Agent.Storyboard
  alias Bezalel.Library.{Conversation, Message, Tool, Transcript}
  alias Bezalel.{Models, Repo}
  alias Rho.Session

  defmodule Undo do
    @moduledoc """
    What a delete needs to be undone: the conversation, the leaf before
    the delete (`before`) and after it (`after`), and the deleted messages.
    """
    @type t :: %__MODULE__{
            conversation_id: integer(),
            before: String.t() | nil,
            after: String.t() | nil,
            messages: [Bezalel.Library.Message.t()]
          }
    defstruct [:conversation_id, :before, :after, messages: []]
  end

  # ── Conversations ─────────────────────────────────────────────────────────

  @doc """
  Conversations, most recently active first, each with its message count.
  `opts`: `:limit`, `:offset` (paging the shelf).
  """
  @spec list_conversations(keyword()) :: [
          %{conversation: Conversation.t(), message_count: non_neg_integer()}
        ]
  def list_conversations(opts \\ []) do
    from(c in Conversation,
      order_by: [desc: c.updated_at, desc: c.id],
      select: %{conversation: c, message_count: c.message_count}
    )
    |> limit(^Keyword.get(opts, :limit, -1))
    |> offset(^Keyword.get(opts, :offset, 0))
    |> Repo.all()
  end

  @doc "A conversation by id, or nil."
  @spec get_conversation(integer() | nil) :: Conversation.t() | nil
  def get_conversation(nil), do: nil
  def get_conversation(id), do: Repo.get(Conversation, id)

  @doc "The most recently active conversation, or nil when there are none."
  @spec latest_conversation() :: Conversation.t() | nil
  def latest_conversation do
    Repo.one(from(c in Conversation, order_by: [desc: c.updated_at, desc: c.id], limit: 1))
  end

  @doc "Starts a conversation (its session is created when it's first written)."
  @spec create_conversation(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create_conversation(attrs) do
    %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()
  end

  @doc "How many conversations are stored."
  @spec conversation_count() :: non_neg_integer()
  def conversation_count, do: Repo.aggregate(Conversation, :count)

  # ── Sessions ──────────────────────────────────────────────────────────────

  @doc """
  The conversation's session for a loop to resume, with the entries on
  its active branch; a new one (recorded on the shelf, written by its
  first entry) for a conversation that has none. `model` is the req_llm
  spec a new session starts on.
  """
  @spec session(integer(), String.t()) ::
          {:ok, Session.t(), [Session.entry()]} | {:error, :not_found}
  def session(conversation_id, model) do
    case get_conversation(conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        {session, branch} = open(conversation, model)
        {:ok, session, branch}
    end
  end

  @doc "Where a conversation's session is, or nil before it has one."
  @spec session_path(Conversation.t() | integer()) :: String.t() | nil
  def session_path(%Conversation{session_file: nil}), do: nil
  def session_path(%Conversation{session_file: file}), do: Path.join(Session.dir(), file)
  def session_path(id), do: id |> get_conversation() |> then(&(&1 && session_path(&1)))

  @doc "The session file of the conversation whose session is `session_id`, or nil."
  @spec session_path_by_id(String.t()) :: String.t() | nil
  def session_path_by_id(session_id) do
    Repo.one(from(c in Conversation, where: c.session_id == ^session_id, limit: 1))
    |> then(&(&1 && session_path(&1)))
  end

  # ── Messages ──────────────────────────────────────────────────────────────

  # The messages last read or written, per process (the screen's, in the
  # app): one session's, with the file's size, mtime and inode when they
  # were read. A session only grows, so any write (a loop's too, which
  # Bezalel doesn't see) changes the size and the next read decodes the
  # file again; Bezalel's own writes leave the messages of the branch they
  # made. Edits always read the file: they need the entries, not the
  # messages.
  @memo {__MODULE__, :shown}

  @doc """
  A conversation's messages in order, read off its session's active
  branch. Reading them again before the session changes doesn't decode
  the file again (the last session read or written in this process is
  remembered).
  """
  @spec messages(integer()) :: [Message.t()]
  def messages(conversation_id) do
    case get_conversation(conversation_id) do
      %Conversation{session_file: file} = c when is_binary(file) -> shown(c)
      _ -> []
    end
  end

  defp shown(%Conversation{} = c) do
    path = session_path(c)
    # Before reading: a write during the read makes the next look miss.
    stamp = stamp(path)

    case Process.get(@memo) do
      {^path, ^stamp, messages} when stamp != nil ->
        messages

      _ ->
        {session, branch} = open(c, Models.default())
        remember(path, stamp, Transcript.messages(branch, session.id))
    end
  end

  defp remember(_path, nil, messages), do: messages

  defp remember(path, stamp, messages) do
    Process.put(@memo, {path, stamp, messages})
    messages
  end

  defp stamp(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime, inode: inode}} -> {size, mtime, inode}
      {:error, _} -> nil
    end
  end

  @doc """
  Records that the conversation's loop wrote to its session: the shelf's
  message count follows, and the conversation moves to the top.
  """
  @spec touch(integer()) :: :ok
  def touch(conversation_id) do
    shelve(conversation_id, length(messages(conversation_id)), true)
  end

  @doc """
  Appends a message and marks the conversation active. `attrs` takes
  `:role` plus `:text` (user), or `:blocks`, `:passage`, `:card`,
  `:image`, `:model` (a reply Bezalel writes: the storyboard's). Returns
  the message as the chat reads it. The conversation must have no loop.
  """
  @spec add_message(Conversation.t(), map()) :: {:ok, Message.t()} | {:error, :empty}
  def add_message(%Conversation{}, %{role: :user, text: text}) when text in [nil, ""],
    do: {:error, :empty}

  def add_message(%Conversation{} = conversation, %{role: :user, text: text}),
    do: append(conversation, [Transcript.user(text)])

  def add_message(%Conversation{} = conversation, %{role: :agent} = attrs),
    do: append(conversation, [Transcript.reply(attrs)])

  # The row is read again: the caller's copy may predate its session.
  defp append(%Conversation{id: id}, entries) do
    {session, branch} = open(get_conversation(id), Models.default())
    {session, added} = write(session, entries)
    {:ok, id |> written(session, extend(branch, added), true) |> List.last()}
  end

  @doc """
  Deletes messages (by `Bezalel.Library.Message` id): the conversation's
  session branches without their entries. Returns what Undo needs. The
  conversation must have no loop.
  """
  @spec delete_messages(integer(), [String.t()]) :: {:ok, Undo.t()} | {:error, :not_found}
  def delete_messages(conversation_id, ids) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {session, branch} = open(c, Models.default()),
         shown = Transcript.messages(branch, session.id),
         [_ | _] = gone <- Enum.filter(shown, &(&1.id in ids)),
         {parent, copies} <- Transcript.delete(branch, Enum.flat_map(gone, & &1.entries)) do
      {moved, added} = move(session, parent, copies)
      written(conversation_id, moved, extend(branch, added), false)

      {:ok,
       %Undo{
         conversation_id: conversation_id,
         before: session.leaf_id,
         after: moved.leaf_id,
         messages: gone
       }}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Undoes a delete: the branch from before it, with anything added since
  copied after. `{:error, :gone}` when the session moved on another way.
  The conversation must have no loop.
  """
  @spec restore(Undo.t()) :: :ok | {:error, :gone}
  def restore(%Undo{conversation_id: id, before: before, after: after_leaf}) do
    with %Conversation{session_file: file} = c when is_binary(file) <- get_conversation(id),
         {session, branch} = open(c, Models.default()),
         {parent, copies} <- Transcript.undo(branch, before, after_leaf) do
      {moved, added} = move(session, parent, copies)
      # The branch it goes back to isn't the one read: read again.
      written(id, moved, extend(branch, added), false)
      :ok
    else
      _ -> {:error, :gone}
    end
  end

  @doc """
  Takes the last question back off the session, to ask it again (Try
  again, Ask again): `{:ok, text}`, or `:none` when the conversation
  doesn't end in one. The conversation must have no loop.
  """
  @spec take_question(integer()) :: {:ok, String.t()} | :none
  def take_question(conversation_id) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {session, branch} = open(c, Models.default()),
         {{parent, copies}, text} <- Transcript.take_question(branch) do
      {moved, added} = move(session, parent, copies)
      written(conversation_id, moved, extend(branch, added), false)
      {:ok, text}
    else
      _ -> :none
    end
  end

  @doc """
  Drops a failed reply's entries (after the last question) from the
  session: the chat shows the failure until it's asked again. The
  conversation must have no loop.
  """
  @spec drop_failed(integer()) :: :ok
  def drop_failed(conversation_id) do
    with %Conversation{session_file: file} = c when is_binary(file) <-
           get_conversation(conversation_id),
         {session, branch} = open(c, Models.default()),
         {parent, copies} <- Transcript.drop_after_question(branch) do
      {moved, added} = move(session, parent, copies)
      written(conversation_id, moved, extend(branch, added), false)
      :ok
    else
      _ -> :ok
    end
  end

  # The conversation's session and its active branch.
  defp open(%Conversation{session_file: nil} = c, model) do
    session = Session.new(Session.dir(), model, Rho.Config.data_dir())

    Repo.update_all(from(x in Conversation, where: x.id == ^c.id),
      set: [session_id: session.id, session_file: Path.basename(session.path)]
    )

    {session, []}
  end

  defp open(%Conversation{} = c, model) do
    path = session_path(c)

    case Session.open(path, model) do
      {:ok, session, branch} ->
        {session, branch}

      # Recorded but never written (a loop that started and wrote nothing).
      {:error, _} ->
        {%Session{id: c.session_id, path: path, cwd: Rho.Config.data_dir(), model: model}, []}
    end
  end

  # Appends `entries`; returns the session and the entries as written, or
  # nil for them when the file ended in a torn line (an append joins it, so
  # neither reads back: what the file holds is read again).
  defp write(session, entries) do
    torn? = torn?(session)

    {session, added} =
      Enum.reduce(entries, {session, []}, fn entry, {s, added} ->
        {s, entry} = Session.append(s, entry)
        {s, [entry | added]}
      end)

    {session, if(torn?, do: nil, else: Enum.reverse(added))}
  end

  defp torn?(%Session{written?: false}), do: false

  defp torn?(%Session{path: path}) do
    with {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(path),
         {:ok, last} <- File.open(path, [:read, :binary], &:file.pread(&1, size - 1, 1)) do
      last != {:ok, "\n"}
    else
      _ -> false
    end
  end

  # Puts the leaf under `parent` and appends `copies`; a marker when there
  # is nothing to copy.
  defp move(session, parent, copies) do
    write(%{session | leaf_id: parent}, if(copies == [], do: [Transcript.marker()], else: copies))
  end

  # The branch once `added` is appended, as far as the messages go: up to
  # the first one's parent on `branch`, then `added`. A new session's first
  # entries follow the model change it starts with, which shows no
  # message. nil when the parent isn't on `branch` (Undo goes back to
  # another branch) or what was appended isn't known.
  defp extend(_branch, nil), do: nil

  defp extend(branch, [first | _] = added) do
    case {first["parentId"], branch} do
      {nil, _} ->
        added

      {_parent, []} ->
        added

      {parent, branch} ->
        case Enum.split_while(branch, &(&1["id"] != parent)) do
          {before, [at | _]} -> before ++ [at | added]
          {_, []} -> nil
        end
    end
  end

  # After a write: the messages on the new branch (read off the file when
  # it isn't known), remembered, and the shelf's count; `active?` moves the
  # conversation to the top.
  defp written(conversation_id, _session, nil, active?) do
    messages = conversation_id |> get_conversation() |> shown()
    shelve(conversation_id, length(messages), active?)
    messages
  end

  defp written(conversation_id, session, branch, active?) do
    messages =
      remember(session.path, stamp(session.path), Transcript.messages(branch, session.id))

    shelve(conversation_id, length(messages), active?)
    messages
  end

  defp shelve(conversation_id, count, active?) do
    set = if active?, do: [updated_at: DateTime.utc_now()], else: []

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [message_count: count] ++ set
    )

    :ok
  end

  # ── Tools ─────────────────────────────────────────────────────────────────

  @doc "Built tools, newest first."
  @spec list_tools() :: [Tool.t()]
  def list_tools, do: Repo.all(from(t in Tool, order_by: [desc: t.inserted_at, desc: t.id]))

  @doc "A tool by id, or nil."
  @spec get_tool(integer() | nil) :: Tool.t() | nil
  def get_tool(nil), do: nil
  def get_tool(id), do: Repo.get(Tool, id)

  @doc "Saves a built tool."
  @spec create_tool(map()) :: {:ok, Tool.t()} | {:error, Ecto.Changeset.t()}
  def create_tool(attrs), do: %Tool{} |> Tool.changeset(attrs) |> Repo.insert()

  @doc "How many tools are stored."
  @spec tool_count() :: non_neg_integer()
  def tool_count, do: Repo.aggregate(Tool, :count)

  # ── First run ─────────────────────────────────────────────────────────────

  @doc """
  On first run (no conversations yet) stores the design's opening study,
  Exodus 31 · Bezalel, so the app opens on a worked example. Does nothing
  once any conversation exists. Returns the conversation to open.
  """
  @spec seed!() :: Conversation.t()
  def seed! do
    latest_conversation() || seed_exodus_31!()
  end

  defp seed_exodus_31! do
    {:ok, c} =
      create_conversation(%{
        name: "Exodus 31 · Bezalel",
        kicker: "SERMON PREP · EXODUS 31",
        kind: "Sermon prep"
      })

    {:ok, _} =
      append(c, [
        Transcript.user("Help me prepare a sermon on Bezalel — what’s the heart of it?"),
        Transcript.reply(%{
          model: "storyboard",
          passage: "exodus-31-2-3",
          blocks: Storyboard.opening_blocks()
        }),
        Transcript.user("Show me the lampstand he made."),
        Transcript.reply(%{model: "storyboard", image: "lampstand"})
      ])

    get_conversation(c.id)
  end
end
