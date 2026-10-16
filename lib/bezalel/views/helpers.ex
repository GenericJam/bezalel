defmodule Bezalel.Views.Helpers do
  @moduledoc "Socket helpers shared by the tab views."

  alias Bezalel.{Agent, Library, Models, Settings}
  alias Bezalel.Agent.Reply
  alias Bezalel.Views.{Conversations, Images, Workshop}
  alias Mob.Socket

  @toast_ms 4000

  @doc """
  Re-reads the open conversation's messages (`visible_messages/2`) and
  starts loading their pictures.
  """
  def reload_messages(socket) do
    socket
    |> Socket.assign(:messages, visible_messages(socket, socket.assigns.conversation.id))
    |> Images.load()
  end

  @doc """
  A conversation's messages as the chat shows them: without the ones
  whose delete waits for the reply streaming in it (`:edits`), and, while
  a reply streams, without what the loop has already written of it (the
  stream draws that), keeping the parts of the run that are done (a reply
  steered into the next).
  """
  def visible_messages(socket, cid) do
    hidden = for {:delete, ids} <- Map.get(socket.assigns.edits, cid, []), id <- ids, do: id

    cid
    |> Library.messages()
    |> without_stream(socket.assigns.streams[cid])
    |> Enum.reject(&(&1.id in hidden))
  end

  # A run starts with its question: what follows the last one is the run's.
  defp without_stream(messages, %Reply{status: :running, kept: kept}) do
    {streaming, done} = messages |> Enum.reverse() |> Enum.split_while(&(&1.role == :agent))
    Enum.reverse(done) ++ Enum.filter(Enum.reverse(streaming), &(&1.entries -- kept == []))
  end

  defp without_stream(messages, _reply), do: messages

  @doc """
  Shows a toast for four seconds. `opts`: `:undo` (what puts a deleted
  message back: a `Bezalel.Library.Undo`, or `{:pending, conversation_id,
  message_id}` for a delete still waiting for its conversation's reply),
  `:ask_again` (offer a fresh reply).
  """
  def toast(socket, text, opts \\ []) do
    ref = make_ref()
    Process.send_after(self(), {:toast_expire, ref}, @toast_ms)

    Socket.assign(socket, :toast, %{
      ref: ref,
      text: text,
      undo: Keyword.get(opts, :undo),
      ask_again: Keyword.get(opts, :ask_again, false)
    })
  end

  @doc "The chosen model."
  def model(socket), do: Models.get(socket.assigns.model_id)

  @doc """
  Switches to `tab`, loading what it shows into assigns (renders don't
  query): the shelf, the built tools and how each is doing, or the
  on-this-phone counts. Leaving a built tool's panel stops its screen.
  """
  def go(socket, tab), do: socket |> Workshop.close_panel() |> to(tab)

  defp to(socket, :convs), do: socket |> Socket.assign(:tab, :convs) |> Conversations.load()

  defp to(socket, :workshop) do
    tools = Library.list_tools()

    Socket.assign(socket,
      tab: :workshop,
      tools: tools,
      tool_status: Map.new(tools, &{&1.id, Bezalel.Workshop.status(&1)})
    )
  end

  defp to(socket, :settings) do
    Socket.assign(socket,
      tab: :settings,
      counts: %{conversations: Library.conversation_count(), tools: Library.tool_count()}
    )
  end

  defp to(socket, tab), do: Socket.assign(socket, :tab, tab)

  @doc "Reloads the visible tab's data after something changed underneath it."
  def refresh(%{assigns: %{tab: tab}} = socket) when tab in [:convs, :workshop, :settings],
    do: to(socket, tab)

  def refresh(socket), do: socket

  @doc """
  Shows a built tool (its panel, `Bezalel.Views.Workshop.open_panel/2`), or
  the Workshop if it's gone.
  """
  def open_tool(socket, id) do
    case Library.get_tool(id) do
      nil -> go(socket, :workshop)
      tool -> Workshop.open_panel(socket, tool)
    end
  end

  @doc """
  Opens a conversation in Study. A toast from the previous one (its Undo and
  Ask again act on that conversation) is dropped. The agent's loops of the
  other conversations go, unless their reply is still streaming (they go
  when it ends).
  """
  def open_conversation(socket, conversation) do
    Settings.put_conversation_id(conversation.id)
    messages = visible_messages(socket, conversation.id)
    live_summary = live_id(conversation.id) <> ":sum"

    expanded =
      if Map.has_key?(socket.assigns.streams, conversation.id),
        do: MapSet.put(summaries_open(messages), live_summary),
        else: summaries_open(messages)

    socket
    |> Workshop.close_panel()
    |> Socket.assign(
      conversation: conversation,
      messages: messages,
      menu: nil,
      toast: nil,
      switched: false,
      draft: ""
    )
    |> Socket.assign(:expanded, expanded)
    |> Socket.assign(:tab, :study)
    |> release_unused()
    |> Images.load()
  end

  defp release_unused(socket) do
    %{sessions: sessions, streams: streams, conversation: %{id: open}} = socket.assigns

    gone =
      for cid <- sessions |> Map.values() |> Enum.uniq(),
          cid != open and not Reply.running?(streams[cid]),
          into: MapSet.new() do
        :ok = Agent.release(cid)
        cid
      end

    sessions = Map.reject(sessions, fn {_sid, cid} -> MapSet.member?(gone, cid) end)
    Socket.assign(socket, :sessions, sessions)
  end

  @doc "Whether a reply to the open conversation is on its way (scripted or live)."
  def replying?(assigns) do
    id = assigns.conversation.id
    Map.get(assigns.replying, id, 0) > 0 or Reply.running?(Map.get(assigns.streams, id))
  end

  @doc "The id a conversation's streaming reply's blocks are keyed under (`block_key/2`)."
  def live_id(conversation_id), do: "live-#{conversation_id}"

  @doc "Summaries start open; thinking and tool calls folded (the design's default)."
  def summaries_open(messages) do
    for m <- messages,
        m.role == :agent,
        b <- m.blocks,
        b["id"] == "sum",
        into: MapSet.new(),
        do: block_key(m, b)
  end

  @doc "The key a block's open state is kept under."
  def block_key(message, block), do: "#{message.id}:#{block["id"]}"

  @doc "Uppercase date label for the shelf: THIS WEEK · OCT 18, or OCT 11."
  def when_label(%DateTime{} = at, now \\ DateTime.utc_now()) do
    day = at |> Calendar.strftime("%b %-d") |> String.upcase()
    if DateTime.diff(now, at, :day) < 7, do: "THIS WEEK · " <> day, else: day
  end

  @doc ~s|Singular or plural count: `count(3, "message")` → "3 messages".|
  def count(1, noun), do: "1 #{noun}"
  def count(n, noun), do: "#{n} #{noun}s"
end
