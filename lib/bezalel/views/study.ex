defmodule Bezalel.Views.Study do
  @moduledoc """
  The Study tab: the conversation with the agent. Replies fold to their type
  and first line; a cited passage's highlighted words open the Hebrew; any
  message can be copied or deleted from its ⋯ menu (deleting further up asks
  first, and every delete can be undone).
  """
  import Mob.Sigil

  alias Bezalel.{Agent, Library, Models, Scripture}
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.{Icons, UI}

  # ── View ──────────────────────────────────────────────────────────────────

  @doc "The Study body: the scrolling conversation and the composer under it."
  def render(assigns) do
    model = Models.get(assigns.model_id)
    rows = Enum.map(assigns.messages, &message(&1, assigns, model))
    draft_change = {self(), :draft}
    send_tap = {self(), {:study, :send}}
    build_tap = {self(), {:study, :build_from_chat}}
    hammer = Icons.icon(:hammer, 18, :secondary)

    ~MOB"""
    <Column weight={1} fill_width={true}>
      <Scroll weight={1} background={:background}>
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
            :if={@messages == []}
            text="Ask about a passage to begin. Replies cite Scripture, and you can tap a highlighted word for its Hebrew."
            text_size={14}
            line_height={1.5}
            text_color={:muted}
          />
          {rows}
          <Text
            :if={Helpers.replying?(assigns)}
            text={replying_label(model)}
            font={:ui_medium}
            text_size={12}
            text_color={:muted}
          />
          {switch_note(@switched, model)}
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
      {UI.composer(@draft, "Ask about this passage…", draft_change, send_tap)}
    </Column>
    """
  end

  defp replying_label(model) do
    if Agent.live?(), do: model.name <> " is replying…", else: "Scripted reply on its way…"
  end

  defp switch_note(false, _model), do: []

  defp switch_note(true, model) do
    label =
      if Agent.live?(),
        do: "Now answering with " <> model.name,
        else: model.name <> " chosen · replies stay scripted until it’s connected"

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

  defp message(%{role: :user} = m, assigns, _model) do
    ~MOB"""
    <Column gap={6} fill_width={true}>
      {UI.user_bubble(m.text)}
      <Box align="top_trailing" fill_width={true}>
        {actions(m, assigns, nil)}
      </Box>
    </Column>
    """
  end

  defp message(%{role: :agent} = m, assigns, current_model) do
    blocks = Enum.map(m.blocks, &block(m, &1, assigns.expanded))

    ~MOB"""
    <Column gap={8} fill_width={true}>
      {blocks}
      {passage(m.passage)}
      {image(m, current_model)}
      {actions(m, assigns, Models.attribution(m.model))}
    </Column>
    """
  end

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
        if word_key do
          tap = {self(), {:study, {:word, word_key}}}
          ~MOB(<Text
  text={token}
  font={:scripture_semibold}
  text_size={19}
  text_color={:secondary}
  on_tap={tap}
/>)
        else
          ~MOB(<Text text={token} font={:scripture} text_size={19} text_color={:on_surface} />)
        end
      end

    UI.card(
      [
        ~MOB"""
        <Row fill_width={true}>
          {UI.kicker(p.ref)}
          <Spacer />
          {UI.kicker(p.version)}
        </Row>
        """,
        ~MOB"""
        <Wrap spacing={5} run_spacing={2} fill_width={true}>
          {words}
        </Wrap>
        """,
        ~MOB(<Text text="Tap a highlighted word for the Hebrew" text_size={12} text_color={:muted} />)
      ],
      padding: 16,
      gap: 10
    )
  end

  defp image(%{image: nil}, _model), do: []

  defp image(%{image: subject}, model) do
    if Models.draws?(model), do: drawing(subject, model), else: no_drawing(model)
  end

  defp drawing(subject, model) do
    caption = "#{subject}, Ex 37:17–24"
    mark = Icons.mark(64, :border, cutout: :surface)

    note =
      if Agent.live?(),
        do: "Drawn by #{model.name} · beaten gold, almond-blossom cups, seven lamps",
        else: "#{model.name} draws this once a model is connected"

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

  defp no_drawing(model) do
    text =
      "#{model.name} doesn’t draw images. Switch to Gemini Pro to see this one; the conversation stays put."

    UI.card(
      [
        ~MOB(<Text text={text} text_size={14} line_height={1.5} text_color={:on_surface} />),
        UI.pill_button(
          "Switch to Gemini Pro",
          {self(), {:study, :draw_with_image_model}},
          :outline,
          height: 36,
          fill: false,
          text_size: 13
        )
      ],
      padding: 14,
      gap: 10
    )
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
    keys = all_block_keys(assigns.messages)

    if keys != [] and Enum.all?(keys, &MapSet.member?(assigns.expanded, &1)),
      do: "Collapse all",
      else: "Expand all"
  end

  defp all_block_keys(messages),
    do: for(m <- messages, b <- m.blocks, do: Helpers.block_key(m, b))

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Handles a Study event."
  def handle(:send, socket) do
    text = String.trim(socket.assigns.draft)

    if text == "" do
      {:noreply, socket}
    else
      {:ok, _} = Library.add_message(socket.assigns.conversation, %{role: :user, text: text})

      {:noreply,
       socket
       |> Socket.assign(draft: "", menu: nil)
       |> Helpers.reload_messages()
       |> respond()}
    end
  end

  def handle(:toggle_all, socket) do
    keys = all_block_keys(socket.assigns.messages)
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
        {:noreply, socket |> Socket.assign(:toast, nil) |> Helpers.reload_messages()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle(:ask_again, socket),
    do: {:noreply, socket |> Socket.assign(:toast, nil) |> respond()}

  def handle({:word, key}, socket),
    do: {:noreply, Socket.assign(socket, sheet: {:word, key}, menu: nil)}

  def handle({:ask_word, key}, socket) do
    w = Scripture.word(key)

    {:noreply,
     Socket.assign(socket, sheet: nil, tab: :study, draft: "Tell me about “#{w.translit}”")}
  end

  def handle(:build_from_chat, socket) do
    desc =
      "A sermon outline helper for #{passage_ref(socket.assigns.messages)}: big idea, three movements, an illustration for each."

    {:noreply, socket |> Socket.assign(desc: desc, build: nil) |> Helpers.go(:workshop)}
  end

  def handle(:draw_with_image_model, socket) do
    Bezalel.Settings.put_model("gemini")
    {:noreply, Socket.assign(socket, model_id: "gemini", switched: true)}
  end

  @doc """
  Asks the agent for the next reply to the open conversation. The task is
  bound to that conversation and the model chosen now: its result lands
  there even if the user has moved on, and a second send doesn't cancel the
  first (each reply is its own task).
  """
  def respond(socket) do
    %{id: conversation_id} = socket.assigns.conversation
    messages = socket.assigns.messages
    model = Helpers.model(socket)
    replying = Map.update(socket.assigns.replying, conversation_id, 1, &(&1 + 1))

    socket
    |> Socket.assign(:replying, replying)
    |> Socket.start_async({:reply, conversation_id, make_ref()}, fn ->
      {model.id, Agent.reply(messages, model)}
    end)
  end

  @doc "Stores a reply (`handle_async({:reply, conversation_id, _}, ...)`)."
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
        socket |> Socket.assign(:expanded, expanded) |> Helpers.reload_messages()
      else
        socket
      end
    else
      # The conversation went away meanwhile: nothing to add it to.
      nil -> socket
      _failed when current? -> Helpers.toast(socket, "No reply this time.", ask_again: true)
      _failed -> socket
    end
  end

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
        |> Helpers.toast(text, undo: m, ask_again: m.role == :agent and last?)

      {:error, :not_found} ->
        Helpers.reload_messages(socket)
    end
  end

  defp copy_text(%{role: :user, text: text}), do: text

  defp copy_text(%{blocks: blocks, passage: passage, image: image}) do
    summary = for b <- blocks, b["id"] == "sum", do: b["first"] <> " " <> b["rest"]

    cited =
      if p = Scripture.passage(passage), do: ["#{p.text} (#{p.ref}, #{p.version})"], else: []

    drawing = if image, do: ["Image request: #{image}, Ex 37:17–24"], else: []
    Enum.join(summary ++ cited ++ drawing, "\n\n")
  end

  defp passage_ref(messages) do
    Enum.find_value(messages, "this passage", fn m ->
      if p = Scripture.passage(m.passage), do: p.ref
    end)
  end
end
