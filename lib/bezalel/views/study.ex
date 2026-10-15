defmodule Bezalel.Views.Study do
  @moduledoc """
  The Study tab: the conversation with the agent. Replies fold to their type
  and first line; a cited passage's highlighted words open the Hebrew; any
  message can be copied or deleted from its ⋯ menu (deleting further up asks
  first, and every delete can be undone).

  A live reply (`Bezalel.Agent.live?/1`) streams in: rho's loop events
  are folded into a `Bezalel.Agent.Reply` per conversation (`streams`,
  found by the loop's session id in `sessions`) and drawn below the stored
  messages, with a stop button in the composer. A message sent while it
  streams steers it; once the loop takes it in, the reply so far is stored,
  then the message, and the rest streams as the next reply. When the run
  ends the reply is stored with its blocks and passage card; a failed one
  stays as its error, with Try again.
  """
  import Mob.Sigil

  alias Bezalel.{Agent, Library, Models, Scripture}
  alias Bezalel.Agent.{Card, Reply, Storyboard}
  alias Bezalel.Study.{DB, Lexicon}
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.{Icons, UI}
  alias Rho.Session

  # ── View ──────────────────────────────────────────────────────────────────

  @doc "The Study body: the scrolling conversation and the composer under it."
  def render(assigns) do
    model = Models.get(assigns.model_id)
    live? = Agent.live?(assigns.account)
    stream = Map.get(assigns.streams, assigns.conversation.id)
    rows = Enum.map(assigns.messages, &message(&1, assigns))
    draft_change = {self(), :draft}
    send_tap = {self(), {:study, :send}}
    build_tap = {self(), {:study, :build_from_chat}}
    hammer = Icons.icon(:hammer, 18, :secondary)

    composer_opts =
      if Reply.running?(stream), do: [stop: {self(), {:study, :stop}}], else: []

    ~MOB"""
    <Column weight={1} fill_width={true}>
      <Scroll id={"study-#{@conversation.id}"} anchor="bottom" weight={1} background={:background}>
        <Column
          padding_left={16}
          padding_right={16}
          padding_top={18}
          padding_bottom={16}
          gap={14}
          fill_width={true}
        >
          <Text
            text={@conversation.kicker}
            font={:ui_semibold}
            text_size={10}
            letter_spacing={1.4}
            text_color={:muted}
            text_align="center"
            fill_width={true}
          />
          <Text
            :if={@messages == [] and stream == nil}
            text="Ask about a passage to begin. Replies cite Scripture, and you can tap a highlighted word for its Hebrew."
            text_size={14}
            line_height={1.5}
            text_color={:muted}
          />
          {rows}
          {live(stream, assigns)}
          <Text
            :if={Helpers.replying?(assigns)}
            text={replying_label(stream)}
            font={:ui_medium}
            text_size={12}
            text_color={:muted}
          />
          {switch_note(@switched, model, live?)}
          <Box
            :if={@messages != []}
            border_color={:border}
            border_width={1}
            corner_radius={20}
            height={40}
            padding_left={12}
            padding_right={16}
            align="center"
            fill_width={false}
            on_tap={build_tap}
          >
            <Row gap={8} align={:center}>
              {hammer}
              <Text
                text="Build a sermon outline tool from this"
                font={:ui_medium}
                text_size={14}
                text_color={:on_background}
              />
            </Row>
          </Box>
        </Column>
      </Scroll>
      {UI.composer(@draft, "Ask about this passage…", draft_change, send_tap, composer_opts)}
    </Column>
    """
  end

  defp replying_label(%Reply{status: :running} = r),
    do: r.retry || Models.get(r.model).name <> " is replying…"

  defp replying_label(_scripted), do: "Scripted reply on its way…"

  defp switch_note(false, _model, _live?), do: []

  defp switch_note(true, model, live?) do
    label =
      if live?,
        do: "Now answering with " <> model.name,
        else: model.name <> " chosen · replies stay scripted until you sign in or add a key"

    ~MOB"""
    <Box align="center" fill_width={true}>
      <Box
        background={:surface}
        border_color={:border}
        border_width={1}
        corner_radius={14}
        padding_left={12}
        padding_right={12}
        padding_top={6}
        padding_bottom={6}
        fill_width={false}
      >
        <Text text={label} font={:ui_medium} text_size={12} text_color={:muted} />
      </Box>
    </Box>
    """
  end

  defp message(%{role: :user} = m, assigns) do
    ~MOB"""
    <Column gap={6} fill_width={true}>
      {UI.user_bubble(m.text)}
      <Box align="top_trailing" fill_width={true}>
        {actions(m, assigns, nil)}
      </Box>
    </Column>
    """
  end

  defp message(%{role: :agent} = m, assigns) do
    blocks = Enum.map(m.blocks, &block(m, &1, assigns.expanded))

    ~MOB"""
    <Column gap={8} fill_width={true}>
      {blocks}
      {passage(m.passage)}
      {card(m.card)}
      {image(m)}
      {actions(m, assigns, Models.attribution(m.model))}
    </Column>
    """
  end

  # The reply streaming in (or failed): its blocks and card so far, the
  # messages waiting to steer it, and its error.
  defp live(nil, _assigns), do: []

  defp live(r, assigns) do
    pseudo = %{id: live_id(r.conversation_id)}
    blocks = Enum.map(Reply.blocks(r), &block(pseudo, &1, assigns.expanded))
    pending = Enum.map(r.pending, &queued/1)

    ~MOB"""
    <Column gap={8} fill_width={true}>
      {blocks}
      {card(r.card)}
      {pending}
      {failure(r)}
    </Column>
    """
  end

  defp queued(text) do
    ~MOB"""
    <Column gap={4} fill_width={true}>
      {UI.user_bubble(text)}
      <Text
        text="Queued: the reply takes it in at its next step"
        text_size={11}
        text_color={:muted}
        text_align="right"
        fill_width={true}
      />
    </Column>
    """
  end

  defp failure(%Reply{status: :error, error: error}) do
    retry = {self(), {:study, :retry}}
    settings = {self(), {:tab, :settings}}
    button_opts = [height: 40, fill: false, text_size: 13]

    buttons =
      [UI.pill_button("Try again", retry, :outline, button_opts)] ++
        if (error || "") =~ "Settings",
          do: [UI.pill_button("Open Settings", settings, :outline, button_opts)],
          else: []

    UI.card(
      [
        UI.kicker("No reply", :error),
        ~MOB(<Text
  text={error || "The reply failed."}
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>),
        ~MOB(<Row gap={10} fill_width={true}>
  {buttons}
</Row>)
      ],
      padding: 16,
      gap: 10
    )
  end

  defp failure(_reply), do: []

  defp block(message, b, expanded) do
    key = Helpers.block_key(message, b)
    kind = if b["id"] == "sum", do: :summary, else: :aside

    UI.block(
      b["type"],
      b["first"],
      b["rest"],
      MapSet.member?(expanded, key),
      {self(), {:study, {:block, key}}},
      kind
    )
  end

  defp passage(nil), do: []

  defp passage(key) do
    p = Scripture.passage(key)

    words =
      for {token, word_key} <- Scripture.tokens(p) do
        if word_key,
          do: word_text(token, {self(), {:study, {:word, word_key}}}),
          else: plain_text(token)
      end

    passage_card(p.ref, p.version, [wrap(words)], "Tap a highlighted word for the Hebrew")
  end

  # A live reply's passage card (`Bezalel.Agent.Card`).
  defp card(nil), do: []

  defp card(c) do
    verses =
      for v <- c["verses"] do
        ref =
          ~MOB(<Text text={v["ref"]} font={:ui_semibold} text_size={11} text_color={:muted} />)

        wrap([ref | Enum.map(v["tokens"], &card_word(&1, c["words"]))])
      end

    more =
      if c["more"] > 0,
        do: [
          ~MOB(<Text text={"+ #{c["more"]} more verses"} text_size={12} text_color={:muted} />)
        ],
        else: []

    hint = if c["words"] == %{}, do: nil, else: "Tap a highlighted word for the original"
    passage_card(c["title"], c["version"], verses ++ more, hint)
  end

  defp card_word([token, strongs], words) do
    case words[strongs] do
      nil -> plain_text(token)
      w -> word_text(token, {self(), {:study, {:lexeme, w}}})
    end
  end

  defp passage_card(ref, version, body, hint) do
    hint =
      if hint, do: [~MOB(<Text text={hint} text_size={12} text_color={:muted} />)], else: []

    UI.card(
      [
        ~MOB"""
        <Row fill_width={true}>
          {UI.kicker(ref)}
          <Spacer />
          {UI.kicker(version)}
        </Row>
        """
        | body ++ hint
      ],
      padding: 16,
      gap: 10
    )
  end

  defp wrap(words) do
    ~MOB"""
    <Wrap spacing={5} run_spacing={2} fill_width={true}>
      {words}
    </Wrap>
    """
  end

  defp word_text(token, tap) do
    ~MOB(<Text
  text={token}
  font={:scripture_semibold}
  text_size={19}
  text_color={:secondary}
  on_tap={tap}
/>)
  end

  defp plain_text(token),
    do: ~MOB(<Text text={token} font={:scripture} text_size={19} text_color={:on_surface} />)

  defp image(%{image: nil}), do: []

  # No model draws here yet: an image request shows its placeholder and
  # says so, whatever the chosen model.
  defp image(%{image: subject}) do
    caption = "#{subject}, Ex 37:17–24"
    mark = Icons.mark(64, :border, cutout: :surface)
    note = "Images are display-only for now: no model draws them here yet."

    ~MOB"""
    <Column gap={8} fill_width={true}>
      <Box
        background={:surface}
        border_color={:border}
        border_width={1}
        corner_radius={18}
        height={200}
        padding={12}
        align="center"
        fill_width={true}
      >
        {mark}
      </Box>
      <Text text={"image · " <> caption} font={:ui_medium} text_size={11} text_color={:muted} />
      <Text text={note} text_size={12} text_color={:muted} />
    </Column>
    """
  end

  defp actions(m, assigns, model_name) do
    more = Icons.icon(:more, 16, :muted)
    menu_tap = {self(), {:study, {:menu, m.id}}}
    open? = assigns.menu == m.id

    chips =
      if open?,
        do: [
          action_chip("Copy", {self(), {:study, {:copy, m.id}}}, :on_surface),
          action_chip("Delete", {self(), {:study, {:delete, m.id}}}, :error)
        ],
        else: []

    name =
      if model_name,
        do: [
          ~MOB(<Text text={model_name} font={:ui_medium} text_size={11} text_color={:muted} />)
        ],
        else: []

    tap_target =
      ~MOB(<Box width={32} height={28} align="center" fill_width={false} on_tap={menu_tap}>
  {more}
</Box>)

    items = if model_name, do: name ++ [tap_target | chips], else: chips ++ [tap_target]

    ~MOB"""
    <Row gap={4} align={:center} fill_width={false}>
      {items}
    </Row>
    """
  end

  defp action_chip(label, tap, color) do
    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={15}
      height={30}
      padding_left={12}
      padding_right={12}
      align="center"
      fill_width={false}
      on_tap={tap}
    >
      <Text text={label} font={:ui_medium} text_size={12} text_color={color} />
    </Box>
    """
  end

  @doc "The top bar's trailing control: Expand all / Collapse all."
  def toggle_all_label(assigns) do
    keys = all_block_keys(assigns)

    if keys != [] and Enum.all?(keys, &MapSet.member?(assigns.expanded, &1)),
      do: "Collapse all",
      else: "Expand all"
  end

  defp all_block_keys(assigns) do
    stored = for m <- assigns.messages, b <- m.blocks, do: Helpers.block_key(m, b)

    case Map.get(assigns.streams, assigns.conversation.id) do
      nil ->
        stored

      r ->
        pseudo = %{id: live_id(r.conversation_id)}
        stored ++ for(b <- Reply.blocks(r), do: Helpers.block_key(pseudo, b))
    end
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @doc """
  Handles a Study event. Sending while a live reply streams steers it;
  while a scripted reply is on its way it waits (the draft stays), so
  replies come back in the order they were asked.
  """
  def handle(:send, socket) do
    text = String.trim(socket.assigns.draft)
    cid = socket.assigns.conversation.id

    cond do
      text == "" ->
        {:noreply, socket}

      Reply.running?(socket.assigns.streams[cid]) ->
        {:noreply, steer(socket, cid, text)}

      Helpers.replying?(socket.assigns) ->
        {:noreply, socket}

      true ->
        {:noreply, ask(socket, text)}
    end
  end

  def handle(:stop, socket) do
    :ok = Agent.stop(socket.assigns.conversation.id)
    {:noreply, socket}
  end

  def handle(:retry, socket) do
    cid = socket.assigns.conversation.id

    if Reply.running?(socket.assigns.streams[cid]) do
      {:noreply, socket}
    else
      {:noreply, socket |> release(cid) |> drop_stream(cid) |> respond()}
    end
  end

  def handle(:toggle_all, socket) do
    keys = all_block_keys(socket.assigns)
    all_open? = keys != [] and Enum.all?(keys, &MapSet.member?(socket.assigns.expanded, &1))
    expanded = if all_open?, do: MapSet.new(), else: MapSet.new(keys)
    {:noreply, Socket.assign(socket, :expanded, expanded)}
  end

  def handle({:block, key}, socket) do
    expanded = socket.assigns.expanded

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, Socket.assign(socket, :expanded, expanded)}
  end

  def handle({:menu, id}, socket) do
    {:noreply, Socket.assign(socket, :menu, if(socket.assigns.menu == id, do: nil, else: id))}
  end

  def handle({:copy, id}, socket) do
    case Enum.find(socket.assigns.messages, &(&1.id == id)) do
      nil ->
        {:noreply, socket}

      m ->
        {:noreply,
         socket
         |> Mob.Clipboard.put(copy_text(m))
         |> Socket.assign(:menu, nil)
         |> Helpers.toast("Copied")}
    end
  end

  def handle({:delete, id}, socket) do
    case Enum.find(socket.assigns.messages, &(&1.id == id)) do
      # Already gone (a double tap, or an event queued across a switch).
      nil ->
        {:noreply, Socket.assign(socket, :menu, nil)}

      _m ->
        if last?(socket.assigns.messages, id),
          do: {:noreply, delete(socket, id)},
          else: {:noreply, Socket.assign(socket, sheet: {:confirm_delete, id}, menu: nil)}
    end
  end

  def handle({:confirm_delete, id}, socket),
    do: {:noreply, socket |> Socket.assign(:sheet, nil) |> delete(id)}

  def handle(:undo, socket) do
    case socket.assigns.toast do
      %{undo: %Library.Message{} = m} ->
        {:ok, _} = Library.restore_message(m)

        {:noreply,
         socket
         |> Socket.assign(:toast, nil)
         |> Helpers.reload_messages()
         |> forget(m.conversation_id)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle(:ask_again, socket) do
    if Helpers.replying?(socket.assigns),
      do: {:noreply, Socket.assign(socket, :toast, nil)},
      else: {:noreply, socket |> Socket.assign(:toast, nil) |> respond()}
  end

  def handle({:word, key}, socket),
    do: {:noreply, Socket.assign(socket, sheet: {:word, key}, menu: nil)}

  def handle({:ask_word, key}, socket) do
    w = Scripture.word(key)

    {:noreply,
     Socket.assign(socket, sheet: nil, tab: :study, draft: "Tell me about “#{w.translit}”")}
  end

  # A word of a live reply's card: the sheet opens on what the card holds;
  # the lexicon entry is read from the core pack beside it.
  def handle({:lexeme, w}, socket) do
    strongs = w["strongs"]

    {:noreply,
     socket
     |> Socket.assign(sheet: {:lexeme, w, nil}, menu: nil)
     |> Socket.start_async({:lexicon, strongs}, fn ->
       DB.with_pack(:core, &Lexicon.entry(&1, strongs))
     end)}
  end

  def handle({:ask_lexeme, w}, socket) do
    draft = "Tell me about #{w["word"]} (#{w["translit"]}, #{w["strongs"]})"
    {:noreply, Socket.assign(socket, sheet: nil, tab: :study, draft: draft)}
  end

  def handle(:build_from_chat, socket) do
    desc =
      "A sermon outline helper for #{passage_ref(socket.assigns.messages)}: big idea, three movements, an illustration for each."

    {:noreply, socket |> Socket.assign(desc: desc, build: nil) |> Helpers.go(:workshop)}
  end

  @doc """
  The lexicon entry for the word sheet (`handle_async({:lexicon, strongs},
  ...)`), if the sheet is still on that word.
  """
  def lexicon(strongs, result, socket) do
    case socket.assigns.sheet do
      {:lexeme, %{"strongs" => ^strongs} = w, _} ->
        lex =
          case result do
            {:ok, {:ok, %{} = entry}} -> entry
            _ -> :none
          end

        Socket.assign(socket, :sheet, {:lexeme, w, lex})

      _ ->
        socket
    end
  end

  defp ask(socket, text) do
    {:ok, _} = Library.add_message(socket.assigns.conversation, %{role: :user, text: text})

    socket
    |> Socket.assign(draft: "", menu: nil)
    |> drop_stream(socket.assigns.conversation.id)
    |> Helpers.reload_messages()
    |> respond()
  end

  defp steer(socket, cid, text) do
    case Agent.steer(cid, text) do
      :ok ->
        reply = socket.assigns.streams[cid]

        socket
        |> Socket.assign(draft: "", menu: nil)
        |> put_stream(cid, %{reply | pending: reply.pending ++ [text]})

      # The loop is gone (released meanwhile): ask afresh.
      {:error, :idle} ->
        ask(socket, text)
    end
  end

  @doc """
  Asks for the next reply to the open conversation, bound to that
  conversation and the model chosen now: its result lands there even if
  the user has moved on. Live (`Bezalel.Agent.live?/1`), the reply streams
  as loop events (`agent_event/3`); without a model the storyboard's comes
  back through `handle_async({:reply, ...})` (`replied/3`). Each
  conversation has at most one reply in flight, and replies in different
  conversations run side by side.
  """
  def respond(socket) do
    if Agent.live?(socket.assigns.account),
      do: respond_live(socket),
      else: respond_scripted(socket)
  end

  defp respond_live(socket) do
    %{id: cid} = socket.assigns.conversation
    model = Helpers.model(socket)

    if Models.available?(model, socket.assigns.account) do
      case Agent.ask(cid, socket.assigns.messages, model.id, self()) do
        {:ok, session_id} ->
          socket
          |> Socket.assign(:sessions, Map.put(socket.assigns.sessions, session_id, cid))
          |> put_stream(cid, Reply.new(cid, model.id, session_id))

        {:error, reason} ->
          put_stream(
            socket,
            cid,
            Reply.failed(cid, model.id, "The agent couldn't start: #{inspect(reason)}")
          )
      end
    else
      text =
        "#{model.name} needs a #{Models.needs(model.provider)}. Add one in Settings → " <>
          "Account, or choose a model you have access to."

      put_stream(socket, cid, Reply.failed(cid, model.id, text))
    end
  end

  defp respond_scripted(socket) do
    %{id: conversation_id} = socket.assigns.conversation
    messages = socket.assigns.messages
    model = Helpers.model(socket)
    replying = Map.update(socket.assigns.replying, conversation_id, 1, &(&1 + 1))
    # A loop left from before a sign-out would miss the scripted replies.
    socket
    |> release(conversation_id)
    |> Socket.assign(:replying, replying)
    |> Socket.start_async({:reply, conversation_id, make_ref()}, fn ->
      {model.id, Storyboard.reply(messages, model)}
    end)
  end

  @doc "Stores a scripted reply (`handle_async({:reply, conversation_id, _}, ...)`)."
  def replied(conversation_id, result, socket) do
    replying =
      Map.update(socket.assigns.replying, conversation_id, 0, &max(&1 - 1, 0))

    socket = Socket.assign(socket, :replying, replying)
    current? = socket.assigns.conversation.id == conversation_id

    with {:ok, {model_id, {:ok, reply}}} <- result,
         %Library.Conversation{} = conversation <- Library.get_conversation(conversation_id),
         {:ok, message} <-
           Library.add_message(conversation, %{
             role: :agent,
             blocks: reply.blocks,
             passage: reply.passage,
             model: reply[:by] || model_id
           }) do
      if current? do
        expanded = MapSet.union(socket.assigns.expanded, Helpers.summaries_open([message]))

        socket
        |> Socket.assign(:expanded, expanded)
        |> Helpers.reload_messages()
        |> Helpers.refresh()
      else
        Helpers.refresh(socket)
      end
    else
      # The conversation went away meanwhile: nothing to add it to.
      nil -> socket
      _failed when current? -> Helpers.toast(socket, "No reply this time.", ask_again: true)
      _failed -> socket
    end
  end

  @doc """
  A live loop's event (`{:rho, session_id, event}`), for whichever
  conversation it answers.
  """
  def agent_event(session_id, event, socket) do
    with cid when cid != nil <- socket.assigns.sessions[session_id],
         %Reply{status: :running, session_id: ^session_id} = reply <- socket.assigns.streams[cid] do
      on_event(cid, reply, event, socket)
    else
      _ -> socket
    end
  end

  defp on_event(
         cid,
         reply,
         %{type: :message_end, entry: %{"message" => %{"role" => "user"} = m}},
         socket
       ) do
    text = Session.typed(m)
    if text in reply.pending, do: steered(socket, cid, reply, text), else: socket
  end

  defp on_event(cid, reply, %{type: :agent_end} = event, socket),
    do: finish(socket, cid, Reply.apply(reply, event))

  defp on_event(cid, reply, event, socket), do: put_stream(socket, cid, Reply.apply(reply, event))

  # The loop took a steering message in: the reply so far is done, the
  # message follows it, and the run goes on as the next reply.
  defp steered(socket, cid, reply, text) do
    socket = store(socket, cid, reply)

    case Library.get_conversation(cid) do
      nil -> :ok
      conversation -> {:ok, _} = Library.add_message(conversation, %{role: :user, text: text})
    end

    socket
    |> put_stream(cid, Reply.continue(reply, text))
    |> reload_if_open(cid)
  end

  # Messages sent as the run was ending: after a normal end the loop runs
  # them next, as a new run; at its limits (`:max_iterations`, `:cost_cap`)
  # it drops them, so they go back. A message steered in after the limit's
  # end may have started a run the screen won't follow: the loop goes too.
  defp finish(socket, cid, %Reply{status: :done, reason: reason} = reply)
       when reply.pending == [] or reason in [:max_iterations, :cost_cap] do
    socket = socket |> store(cid, reply) |> drop_stream(cid)

    socket =
      if reply.pending == [], do: release_if_unused(socket, cid), else: release(socket, cid)

    unsend(socket, cid, reply.pending)
  end

  defp finish(socket, cid, %Reply{status: :done} = reply) do
    socket
    |> store(cid, reply)
    |> put_stream(cid, %{Reply.continue(reply, "") | pending: reply.pending})
  end

  # Stopped: what streamed is kept. The loop goes (its session holds the
  # cut-off turn); the next question starts one from the conversation.
  defp finish(socket, cid, %Reply{status: :stopped} = reply) do
    socket
    |> release(cid)
    |> store(cid, reply)
    |> drop_stream(cid)
    |> unsend(cid, reply.pending)
  end

  # Failed: the error stays in the conversation, with Try again (a fresh
  # loop from the conversation as stored).
  defp finish(socket, cid, %Reply{status: :error} = reply) do
    socket
    |> release(cid)
    |> put_stream(cid, %{reply | pending: []})
    |> unsend(cid, reply.pending)
  end

  # Messages the loop didn't take in go back to the draft, or, for a
  # conversation that isn't open, into it as questions for the next reply.
  defp unsend(socket, _cid, []), do: socket

  defp unsend(%{assigns: %{conversation: %{id: cid}}} = socket, cid, texts) do
    draft = Enum.join(texts ++ [socket.assigns.draft], "\n\n") |> String.trim()
    Socket.assign(socket, :draft, draft)
  end

  defp unsend(socket, cid, texts) do
    case Library.get_conversation(cid) do
      nil ->
        socket

      conversation ->
        for text <- texts,
            do: {:ok, _} = Library.add_message(conversation, %{role: :user, text: text})

        Helpers.refresh(socket)
    end
  end

  # Stores the reply (its blocks and card), keeping which blocks were open.
  defp store(socket, cid, reply) do
    with true <- Reply.any?(reply),
         %Library.Conversation{} = conversation <- Library.get_conversation(cid),
         {:ok, message} <-
           Library.add_message(conversation, %{
             role: :agent,
             blocks: Reply.blocks(reply),
             card: reply.card,
             model: reply.model
           }) do
      prefix = live_id(cid) <> ":"

      expanded =
        socket.assigns.expanded
        |> MapSet.new(&String.replace_prefix(&1, prefix, "#{message.id}:"))
        |> MapSet.union(Helpers.summaries_open([message]))

      socket
      |> Socket.assign(:expanded, expanded)
      |> reload_if_open(cid)
      |> Helpers.refresh()
    else
      _ -> socket
    end
  end

  defp reload_if_open(%{assigns: %{conversation: %{id: cid}}} = socket, cid),
    do: Helpers.reload_messages(socket)

  defp reload_if_open(socket, _cid), do: socket

  # The loop of a conversation that's no longer open, or whose messages
  # changed while it ran, goes once its reply is done.
  defp release_if_unused(socket, cid) do
    if cid != socket.assigns.conversation.id or MapSet.member?(socket.assigns.stale, cid),
      do: release(socket, cid),
      else: socket
  end

  # A message deleted or put back: the agent's context no longer matches
  # the conversation, so its loop goes (now, or when its reply is done).
  defp forget(socket, cid) do
    if Reply.running?(socket.assigns.streams[cid]),
      do: Socket.assign(socket, :stale, MapSet.put(socket.assigns.stale, cid)),
      else: release(socket, cid)
  end

  # The conversation's loop goes, and with it its sessions and stale mark.
  defp release(socket, cid) do
    :ok = Agent.release(cid)
    sessions = Map.reject(socket.assigns.sessions, fn {_, c} -> c == cid end)
    Socket.assign(socket, sessions: sessions, stale: MapSet.delete(socket.assigns.stale, cid))
  end

  # A reply starting (a new one, or the next after a steer) opens its
  # summary, as a stored reply's is.
  defp put_stream(socket, cid, reply) do
    expanded =
      if reply.items == [] and reply.summary == "" and reply.text == "",
        do: MapSet.put(socket.assigns.expanded, live_id(cid) <> ":sum"),
        else: socket.assigns.expanded

    Socket.assign(socket,
      streams: Map.put(socket.assigns.streams, cid, reply),
      expanded: expanded
    )
  end

  defp drop_stream(socket, cid) do
    prefix = live_id(cid) <> ":"
    expanded = MapSet.reject(socket.assigns.expanded, &String.starts_with?(&1, prefix))

    Socket.assign(socket,
      streams: Map.delete(socket.assigns.streams, cid),
      expanded: expanded
    )
  end

  defp live_id(cid), do: Helpers.live_id(cid)

  defp last?(messages, id), do: match?(%{id: ^id}, List.last(messages))

  defp delete(socket, id) do
    last? = last?(socket.assigns.messages, id)

    case Library.delete_message(id) do
      {:ok, m} ->
        text =
          if m.role == :agent,
            do: "Reply deleted. The agent won’t see it.",
            else: "Message deleted. The agent won’t see it."

        socket
        |> Socket.assign(:menu, nil)
        |> Helpers.reload_messages()
        |> forget(m.conversation_id)
        |> Helpers.toast(text, undo: m, ask_again: m.role == :agent and last?)

      {:error, :not_found} ->
        Helpers.reload_messages(socket)
    end
  end

  defp copy_text(%{role: :user, text: text}), do: text

  defp copy_text(%{blocks: blocks, passage: passage, card: card, image: image}) do
    summary = for b <- blocks, b["id"] == "sum", do: summary_text(b)

    cited =
      cond do
        p = Scripture.passage(passage) -> ["#{p.text} (#{p.ref}, #{p.version})"]
        card -> [Card.text(card)]
        true -> []
      end

    drawing = if image, do: ["Image request: #{image}, Ex 37:17–24"], else: []
    Enum.join(summary ++ cited ++ drawing, "\n\n")
  end

  # A cut header repeats the whole text under it.
  defp summary_text(%{"cut" => true, "rest" => rest}), do: rest
  defp summary_text(%{"first" => first, "rest" => rest}), do: String.trim(first <> " " <> rest)

  defp passage_ref(messages) do
    Enum.find_value(messages, "this passage", fn m ->
      cond do
        p = Scripture.passage(m.passage) -> p.ref
        m.card -> m.card["title"]
        true -> nil
      end
    end)
  end
end
