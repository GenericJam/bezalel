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

  @doc "A conversation's messages in order, read off its session's active branch."
  @spec messages(integer()) :: [Message.t()]
  def messages(conversation_id) do
    case get_conversation(conversation_id) do
      %Conversation{session_file: file} = c when is_binary(file) ->
        {session, branch} = open(c, Models.default())
        Transcript.messages(branch, session.id)

      _ ->
        []
    end
  end

  @doc """
  Records that the conversation's loop wrote to its session: the shelf's
  message count follows, and the conversation moves to the top.
  """
  @spec touch(integer()) :: :ok
  def touch(conversation_id) do
    count = length(messages(conversation_id))

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [message_count: count, updated_at: DateTime.utc_now()]
    )

    :ok
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
    {session, _branch} = open(get_conversation(id), Models.default())
    _session = Enum.reduce(entries, session, &elem(Session.append(&2, &1), 0))
    touch(id)
    {:ok, id |> messages() |> List.last()}
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
      leaf = move(session, parent, copies)
      recount(conversation_id)

      {:ok,
       %Undo{
         conversation_id: conversation_id,
         before: session.leaf_id,
         after: leaf,
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
      move(session, parent, copies)
      recount(id)
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
      move(session, parent, copies)
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
      move(session, parent, copies)
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

  # Puts the leaf under `parent` and appends `copies`; a marker when there
  # is nothing to copy. Returns the new leaf.
  defp move(session, parent, copies) do
    entries = if copies == [], do: [Transcript.marker()], else: copies

    session =
      Enum.reduce(entries, %{session | leaf_id: parent}, &elem(Session.append(&2, &1), 0))

    session.leaf_id
  end

  defp recount(conversation_id) do
    count = length(messages(conversation_id))

    Repo.update_all(from(c in Conversation, where: c.id == ^conversation_id),
      set: [message_count: count]
    )
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
