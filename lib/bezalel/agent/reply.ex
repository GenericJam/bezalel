defmodule Bezalel.Agent.Reply do
  @moduledoc """
  A live reply as it streams: rho's loop events (`Rho.Events`) folded into
  the design's blocks. Each model call's thinking is a THINKING block, each
  tool call a TOOL CALL block (its name and arguments, the result on
  expand), and the answer the SUMMARY. Text the model writes in a call
  that also calls tools is working narration: it joins that call's
  THINKING. A `lookup_verse` or `word_study` result that names a passage
  becomes the passage card (`Bezalel.Agent.Card`).

  Pictures in a turn or a tool result are listed in `images`.

  Pure: `Bezalel.Views.Study` keeps one per conversation with a reply in
  flight. The loop writes the reply to the conversation's session as it
  goes; once stored, `Bezalel.Library.Transcript` draws it with this same
  fold over its entries.
  """

  alias Bezalel.Agent.Card
  alias Bezalel.Library.Transcript
  alias Bezalel.Study.Patterns
  alias Rho.Session

  @type status :: :running | :done | :stopped | :error

  @type t :: %__MODULE__{
          conversation_id: integer(),
          session_id: String.t() | nil,
          model: String.t(),
          status: status(),
          turn: non_neg_integer(),
          items: [map()],
          text: String.t(),
          summary: String.t(),
          card: Card.t() | nil,
          images: [Bezalel.Library.Message.image()],
          seen: [String.t()],
          kept: [String.t()],
          pending: [String.t()],
          retry: String.t() | nil,
          error: String.t() | nil,
          reason: atom() | nil
        }

  defstruct [
    :conversation_id,
    :session_id,
    :model,
    status: :running,
    turn: 0,
    items: [],
    text: "",
    summary: "",
    card: nil,
    images: [],
    seen: [],
    kept: [],
    pending: [],
    retry: nil,
    error: nil,
    reason: nil
  ]

  # A header line longer than this (about one line on a phone) is cut; the
  # whole text is then the rest, so nothing hides behind the cut.
  @first_max 32
  # Lines and characters of a tool result shown under its call.
  @result_lines 6
  @result_chars 500

  @doc "A reply about to stream in `conversation_id` from `model`."
  @spec new(integer(), String.t(), String.t() | nil) :: t()
  def new(conversation_id, model, session_id \\ nil),
    do: %__MODULE__{conversation_id: conversation_id, model: model, session_id: session_id}

  @doc "A reply that failed before it started (no credential): shown as its error."
  @spec failed(integer(), String.t(), String.t()) :: t()
  def failed(conversation_id, model, error),
    do: %{new(conversation_id, model) | status: :error, error: error}

  @doc "Folds one loop event in."
  @spec apply(t(), map()) :: t()
  def apply(r, %{type: :turn_start, turn: turn}), do: %{r | turn: turn, text: ""}

  def apply(r, %{type: :message_update, kind: :thinking, delta: delta}),
    do: %{update_think(r, &(&1 <> delta)) | retry: nil}

  def apply(r, %{type: :message_update, kind: :text, delta: delta}),
    do: %{r | text: r.text <> delta, retry: nil}

  def apply(r, %{type: :message_end, entry: %{"message" => %{"role" => "assistant"} = m} = entry}) do
    r = r |> saw(entry) |> add_images(entry)

    cond do
      m["stopReason"] == "error" ->
        %{r | error: r.error || m["errorMessage"]}

      Session.tool_calls(m) != [] and String.trim(r.text) != "" ->
        r |> update_think(&join(&1, r.text)) |> Map.put(:text, "")

      true ->
        %{r | summary: join(r.summary, r.text), text: ""}
    end
  end

  def apply(r, %{type: :message_end, entry: %{"message" => %{"role" => "toolResult"}} = entry}),
    do: r |> saw(entry) |> add_images(entry)

  def apply(r, %{type: :message_end, entry: %{"type" => "custom_message"} = entry}) do
    r = saw(r, entry)

    if Session.notice_kind(entry) == :error,
      do: %{r | error: r.error || Session.text(entry["content"])},
      else: r
  end

  # The message being streamed is dropped (a retry, or an overflow
  # compaction): its thinking and text with it.
  def apply(r, %{type: :retry, attempt: attempt, error: error}),
    do: %{discard_attempt(r) | retry: "Retrying (#{attempt}): #{error}"}

  def apply(r, %{type: :compaction_start, reason: :overflow}), do: discard_attempt(r)

  def apply(r, %{type: :tool_execution_start, id: id, name: name, arguments: args}) do
    item = %{
      id: "tool-#{id}",
      kind: :tool,
      name: name,
      args: args,
      result: nil,
      error: false,
      card: nil
    }

    %{r | items: r.items ++ [item]}
  end

  def apply(r, %{type: :tool_execution_end, id: id, name: name} = event) do
    # Replayed from the session (`Bezalel.Library.Transcript`), the card
    # is the one kept with the result; live, it's built from the details.
    card =
      cond do
        event.is_error -> nil
        Map.has_key?(event, :card) -> event.card
        true -> Card.from_tool(name, event[:details])
      end

    items =
      Enum.map(r.items, fn
        %{id: "tool-" <> ^id} = item ->
          %{item | result: event.text, error: event.is_error, card: card}

        item ->
          item
      end)

    %{r | items: items, card: pick_card(r.card, card, name)}
  end

  def apply(r, %{type: :turn_end, error: error}) when is_binary(error),
    do: %{r | error: r.error || error}

  def apply(r, %{type: :agent_end, reason: reason}) do
    status =
      cond do
        r.error != nil or reason == :error -> :error
        reason == :stopped -> :stopped
        true -> :done
      end

    %{r | status: status, reason: reason, retry: nil, summary: join(r.summary, r.text), text: ""}
  end

  def apply(r, _event), do: r

  @doc "Whether the reply is still streaming."
  @spec running?(t() | nil) :: boolean()
  def running?(%__MODULE__{status: :running}), do: true
  def running?(_reply), do: false

  @doc "Whether there's anything to show: a block, a card or a picture."
  @spec any?(t()) :: boolean()
  def any?(r), do: blocks(r) != [] or r.card != nil or r.images != []

  @doc """
  Starts over after the steering message `text` was injected: the reply so
  far is done (the chat shows it from the session now: its entries move to
  `kept`), the run goes on as a new reply. `pending` loses `text`.
  """
  @spec continue(t(), String.t()) :: t()
  def continue(r, text) do
    %{
      new(r.conversation_id, r.model, r.session_id)
      | turn: r.turn,
        pending: r.pending -- [text],
        kept: r.kept ++ r.seen
    }
  end

  @doc """
  The blocks in the design's shape (`%{"id", "type", "first", "rest"}`, plus
  `"cut" => true` when `first` is a cut-short header and `rest` the whole
  text): each call's THINKING and TOOL CALLs in order, then the SUMMARY
  (with the text still streaming).
  """
  @spec blocks(t()) :: [map()]
  def blocks(r) do
    items =
      for item <- r.items, block = item_block(item), do: block

    case plain(join(r.summary, r.text)) do
      "" -> items
      summary -> items ++ [block("sum", "SUMMARY", summary)]
    end
  end

  @doc """
  Model text as the blocks show it: Markdown's emphasis and code marks
  dropped, headings as plain lines, list items as bullets.
  """
  @spec plain(String.t()) :: String.t()
  def plain(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", &plain_line/1)
    |> String.replace(["**", "__", "`", "*"], "")
    |> String.trim()
  end

  defp plain_line(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "#") -> String.trim_leading(trimmed, "#") |> String.trim()
      String.starts_with?(trimmed, ["* ", "- "]) -> "• " <> String.slice(trimmed, 2..-1//1)
      true -> line
    end
  end

  defp item_block(%{kind: :think, id: id, text: text}) do
    case plain(text) do
      "" -> nil
      text -> block(id, "THINKING", text)
    end
  end

  defp item_block(%{kind: :tool} = item) do
    %{"id" => item.id, "type" => "TOOL CALL", "first" => call_label(item), "rest" => result(item)}
  end

  # `"cut"` marks a header cut short: `rest` then holds the whole text.
  defp block(id, type, text) do
    {first, rest, cut?} = split(text)
    b = %{"id" => id, "type" => type, "first" => first, "rest" => rest}
    if cut?, do: Map.put(b, "cut", true), else: b
  end

  # The header line: the first sentence (or line); a long one is cut and
  # the whole text goes under it.
  defp split(text) do
    sentence =
      case Regex.run(Patterns.get(:first_sentence), text) do
        [match] -> String.trim(match)
        nil -> text
      end

    if String.length(sentence) > @first_max,
      do: {cut(sentence), text, true},
      else:
        {sentence, text |> String.slice(String.length(sentence)..-1//1) |> String.trim(), false}
  end

  defp cut(text) do
    head = String.slice(text, 0, @first_max)

    case String.split(head, " ") do
      [_one] -> head <> "…"
      words -> (words |> Enum.drop(-1) |> Enum.join(" ")) <> "…"
    end
  end

  defp call_label(%{name: name, args: args}) when is_map(args) do
    shown =
      Enum.map_join(args, ", ", fn {key, value} ->
        "#{key}: " <> if(is_binary(value), do: inspect(value), else: Jason.encode!(value))
      end)

    "#{name}(#{shown})"
  end

  defp call_label(%{name: name}), do: "#{name}()"

  defp result(%{result: nil}), do: "Running…"

  # A passage reads better as its verses than as the Markdown the model got.
  defp result(%{card: %{} = card}), do: "→ " <> Card.text(card)

  defp result(%{result: text, error: error}) do
    lines =
      text
      |> plain()
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    shown = lines |> Enum.take(@result_lines) |> Enum.join("\n")
    more? = length(lines) > @result_lines or String.length(shown) > @result_chars
    shown = String.slice(shown, 0, @result_chars) <> if(more?, do: "…", else: "")
    if error, do: "Error: " <> shown, else: "→ " <> shown
  end

  # A passage from lookup_verse wins over word_study's examples; the
  # latest of a kind over an earlier one.
  defp pick_card(current, nil, _name), do: current
  defp pick_card(%{"from" => "lookup_verse"} = current, _card, "word_study"), do: current
  defp pick_card(_current, card, _name), do: card

  defp update_think(r, fun) do
    id = "think-#{r.turn}"

    {items, found?} =
      Enum.map_reduce(r.items, false, fn
        %{id: ^id} = item, _found -> {%{item | text: fun.(item.text)}, true}
        item, found -> {item, found}
      end)

    items = if found?, do: items, else: items ++ [%{id: id, kind: :think, text: fun.("")}]
    %{r | items: items}
  end

  # Pictures in a model's turn or a tool's result, keyed as the stored
  # reply's are (`Bezalel.Library.Message`).
  defp add_images(r, entry),
    do: %{r | images: r.images ++ Transcript.images([entry], r.session_id || "")}

  # The session entries the loop wrote for this reply so far (`seen`); the
  # chat leaves them to the stream while it runs.
  defp saw(r, %{"id" => id}), do: %{r | seen: r.seen ++ [id]}
  defp saw(r, _entry), do: r

  defp discard_attempt(r) do
    id = "think-#{r.turn}"
    %{r | text: "", items: Enum.reject(r.items, &(&1.id == id))}
  end

  defp join("", b), do: b
  defp join(a, ""), do: a
  defp join(a, b), do: a <> "\n\n" <> b
end
