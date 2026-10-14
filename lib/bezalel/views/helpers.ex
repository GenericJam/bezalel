defmodule Bezalel.Views.Helpers do
  @moduledoc "Socket helpers shared by the tab views."

  alias Bezalel.{Library, Models, Settings}
  alias Mob.Socket

  @toast_ms 4000

  @doc "Re-reads the open conversation's messages."
  def reload_messages(socket) do
    Socket.assign(socket, :messages, Library.messages(socket.assigns.conversation.id))
  end

  @doc """
  Shows a toast for four seconds. `opts`: `:undo` (a deleted message to put
  back), `:ask_again` (offer a fresh reply).
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

  @doc "Opens a conversation in Study."
  def open_conversation(socket, conversation) do
    Settings.put_conversation_id(conversation.id)
    messages = Library.messages(conversation.id)

    socket
    |> Socket.assign(
      conversation: conversation,
      messages: messages,
      menu: nil,
      typing: false,
      switched: false,
      draft: ""
    )
    |> Socket.assign(:expanded, summaries_open(messages))
    |> Socket.assign(:tab, :study)
  end

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
