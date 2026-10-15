defmodule Bezalel.Library do
  @moduledoc """
  What the app keeps on the phone: conversations, their messages, and the
  tools built in the Workshop.
  """
  import Ecto.Query

  alias Bezalel.Agent.Storyboard
  alias Bezalel.Library.{Conversation, Message, Tool}
  alias Bezalel.Repo

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
      left_join: m in assoc(c, :messages),
      group_by: c.id,
      order_by: [desc: c.updated_at, desc: c.id],
      select: %{conversation: c, message_count: count(m.id)}
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

  @doc "Starts a conversation."
  @spec create_conversation(map()) :: {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def create_conversation(attrs) do
    %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()
  end

  @doc "How many conversations are stored."
  @spec conversation_count() :: non_neg_integer()
  def conversation_count, do: Repo.aggregate(Conversation, :count)

  # ── Messages ──────────────────────────────────────────────────────────────

  @doc "A conversation's messages in order."
  @spec messages(integer()) :: [Message.t()]
  def messages(conversation_id) do
    Repo.all(
      from(m in Message, where: m.conversation_id == ^conversation_id, order_by: m.position)
    )
  end

  @doc """
  Appends a message to a conversation and marks the conversation active.
  `attrs` takes `:role` plus `:text` (user) or `:blocks`, `:passage`,
  `:card`, `:image`, `:model` (agent). The position comes from the conversation's
  counter, so a deleted message's slot is never handed out again.
  """
  @spec add_message(Conversation.t(), map()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def add_message(%Conversation{id: id}, attrs) do
    Repo.transact(fn ->
      # Claim the slot and mark the conversation active in one write.
      {1, [position]} =
        Repo.update_all(
          from(c in Conversation, where: c.id == ^id, select: c.next_position - 1),
          inc: [next_position: 1],
          set: [updated_at: DateTime.utc_now()]
        )

      %Message{}
      |> Message.changeset(Map.merge(attrs, %{conversation_id: id, position: position}))
      |> Repo.insert()
    end)
  end

  @doc """
  Deletes a message and returns it, so `restore_message/1` can put it back
  (the Undo on the toast).
  """
  @spec delete_message(integer()) :: {:ok, Message.t()} | {:error, :not_found}
  def delete_message(id) do
    case Repo.get(Message, id) do
      nil -> {:error, :not_found}
      message -> Repo.delete(message)
    end
  end

  @doc "Puts a deleted message back in its place, with its id."
  @spec restore_message(Message.t()) :: {:ok, Message.t()} | {:error, Ecto.Changeset.t()}
  def restore_message(%Message{} = message) do
    attrs =
      Map.take(message, [
        :conversation_id,
        :position,
        :role,
        :text,
        :blocks,
        :passage,
        :card,
        :image,
        :model
      ])

    %Message{id: message.id, inserted_at: message.inserted_at}
    |> Message.changeset(attrs)
    |> Repo.insert()
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
    {:ok, conversation} =
      Repo.transact(fn ->
        {:ok, c} =
          create_conversation(%{
            name: "Exodus 31 · Bezalel",
            kicker: "SERMON PREP · EXODUS 31",
            kind: "Sermon prep"
          })

        {:ok, _} =
          add_message(c, %{
            role: :user,
            text: "Help me prepare a sermon on Bezalel — what’s the heart of it?"
          })

        {:ok, _} =
          add_message(c, %{
            role: :agent,
            model: "storyboard",
            passage: "exodus-31-2-3",
            blocks: Storyboard.opening_blocks()
          })

        {:ok, _} = add_message(c, %{role: :user, text: "Show me the lampstand he made."})

        {:ok, _} =
          add_message(c, %{role: :agent, model: "storyboard", image: "lampstand"})

        {:ok, c}
      end)

    conversation
  end
end
