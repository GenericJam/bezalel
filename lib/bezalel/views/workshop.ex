defmodule Bezalel.Views.Workshop do
  @moduledoc """
  The Workshop tab (your tools first, then building a new one) and a built
  tool's own panel.
  """
  import Mob.Sigil

  alias Bezalel.{Library, Models, Workshop}
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.{Icons, Palette, UI}

  @starters ["Sermon outline helper", "Word study view", "Reading plan"]

  # ── Workshop ──────────────────────────────────────────────────────────────

  @doc "The Workshop body."
  def render(assigns) do
    model = Models.get(assigns.model_id)
    tools = assigns.tools
    desc_change = {self(), :desc}
    build_tap = {self(), {:workshop, :build}}
    starters = for s <- @starters, do: UI.chip(s, {self(), {:workshop, {:starter, s}}})
    # Android's Material field pads its text itself.
    field_android = %{padding: 0, underline: false}

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={24}
        gap={18}
        fill_width={true}
      >
        <Column gap={10} fill_width={true}>
          <Text text="Your tools" font={:display} text_size={30} text_color={:on_background} />
          <Text
            :if={tools == []}
            text="Nothing built yet. Describe a tool below, or build one from a conversation in Study."
            text_size={13}
            line_height={1.5}
            text_color={:muted}
          />
          {Enum.map(tools, &tool_row/1)}
        </Column>
        <Column gap={6} padding_top={6} fill_width={true}>
          <Text text="Build a new one" font={:display} text_size={22} text_color={:on_background} />
          <Text
            text="“…to devise artistic designs, to work in gold, silver, and bronze.” Ex 31:4"
            font={:scripture_italic}
            text_size={15}
            line_height={1.4}
            text_color={:muted}
          />
        </Column>
        {UI.card(
          [
            ~MOB(<TextField value={@desc} placeholder="Describe a tool in a sentence or two" on_change={desc_change} lines={4} background={:surface} border_color={:surface} text_size={16} android={field_android} padding={4} />),
            ~MOB(<Wrap spacing={8} run_spacing={8} fill_width={true}>{starters}</Wrap>)
          ],
          padding: 14,
          gap: 12
        )}
        {build_state(@build, model, build_tap)}
      </Column>
    </Scroll>
    """
  end

  defp tool_row(tool) do
    tile =
      if tool.kind == "sermon_outline", do: Palette.brand().umber, else: Palette.brand().tekhelet

    hammer = Icons.icon(:hammer, 20, Palette.overlay().mark_gold)
    meta = "Built #{built_when(tool.inserted_at)} · #{tool.data["text"] || tool.description}"
    tap = {self(), {:workshop, {:open_tool, tool.id}}}

    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      padding_left={14}
      padding_right={14}
      padding_top={12}
      padding_bottom={12}
      fill_width={true}
      on_tap={tap}
    >
      <Row gap={14} align={:center} fill_width={true}>
        <Box
          width={40}
          height={40}
          corner_radius={12}
          background={tile}
          align="center"
          fill_width={false}
        >
          {hammer}
        </Box>
        <Column gap={2} weight={1}>
          <Text text={tool.name} font={:display} text_size={18} text_color={:on_surface} />
          <Text text={meta} text_size={12} text_color={:muted} max_lines={1} />
        </Column>
      </Row>
    </Box>
    """
  end

  defp build_label(model) do
    if Workshop.live?(), do: "Build with " <> model.name, else: "Build (scripted)"
  end

  defp build_state(nil, model, tap) do
    UI.pill_button(build_label(model), tap, :primary, height: 52, text_size: 16)
  end

  defp build_state({:failed, reason}, model, tap) do
    [
      UI.card(
        [~MOB(<Text text={reason} text_size={14} line_height={1.5} text_color={:on_surface} />)],
        padding: 14
      ),
      UI.pill_button(build_label(model), tap, :primary, height: 52, text_size: 16)
    ]
  end

  defp build_state({:step, current}, model, _tap) do
    heading =
      if Workshop.live?(),
        do: String.upcase(model.name) <> " IS DRAFTING YOUR TOOL",
        else: "DRAFTING YOUR TOOL (SCRIPTED)"

    steps =
      for {label, i} <- Enum.with_index(Workshop.steps()) do
        fill = if current > i, do: :secondary, else: :surface
        color = if current >= i, do: :on_surface, else: :muted

        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Box
            width={22}
            height={22}
            corner_radius={11}
            border_color={:secondary}
            border_width={1.5}
            background={fill}
            fill_width={false}
          />
          <Text text={label} text_size={15} text_color={color} />
        </Row>
        """
      end

    UI.card(
      [UI.kicker(heading)] ++
        steps ++
        [~MOB(<Text
  text="Once it’s built, the tool lives on your phone and works offline."
  text_size={12}
  line_height={1.45}
  text_color={:muted}
/>)],
      padding: 16,
      gap: 12
    )
  end

  defp built_when(at) do
    days = DateTime.diff(DateTime.utc_now(), at, :day)

    cond do
      days < 1 -> "today"
      days < 7 -> "this week"
      true -> at |> Calendar.strftime("%b %-d")
    end
  end

  # ── A built tool ──────────────────────────────────────────────────────────

  @doc "A built tool's panel."
  def render_tool(assigns) do
    tool = assigns.tool
    data = tool.data
    discuss = {self(), {:tool, :discuss}}
    change = {self(), {:tool, :change}}

    moves =
      data["moves"]
      |> Enum.with_index()
      |> Enum.map(fn {m, i} -> move(m, i, assigns.move_open == i) end)

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={24}
        gap={16}
        fill_width={true}
      >
        <Column gap={6} fill_width={true}>
          <Box
            background={:surface}
            border_color={:border}
            border_width={1}
            corner_radius={12}
            padding_left={9}
            padding_right={9}
            padding_top={4}
            padding_bottom={4}
            fill_width={false}
          >
            {UI.kicker("Built by you · offline")}
          </Box>
          <Text text={tool.name} font={:display} text_size={30} text_color={:on_background} />
        </Column>
        {UI.card([UI.kicker("Text"), ~MOB(<Text text={data["text"]} font={:display} text_size={18} text_color={:on_surface} />)], gap: 4, padding: 14)}
        {UI.card([UI.kicker("Big idea"), ~MOB(<Text text={data["big_idea"]} font={:scripture} text_size={20} line_height={1.35} text_color={:on_surface} />)], gap: 4, padding: 14)}
        {moves}
        <Row gap={10} fill_width={true}>
          {UI.pill_button("Discuss in Study", discuss, :primary, weight: 1)}
          {UI.pill_button("Change the tool", change, :outline, weight: 1)}
        </Row>
      </Column>
    </Scroll>
    """
  end

  defp move(m, i, open?) do
    tap = {self(), {:tool, {:move, i}}}
    sign = Icons.icon(if(open?, do: :chevron_up, else: :chevron_down), 16, :muted)

    points =
      if open?,
        do:
          for(
            p <- m["points"],
            do:
              ~MOB(<Text text={"• " <> p} text_size={14} line_height={1.5} text_color={:on_surface} />)
          ),
        else: []

    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      fill_width={true}
    >
      <Column fill_width={true}>
        <Row
          gap={12}
          align={:center}
          padding_left={16}
          padding_right={16}
          padding_top={14}
          padding_bottom={14}
          fill_width={true}
          on_tap={tap}
        >
          <Text text={m["num"]} font={:display} text_size={20} text_color={:secondary} width={26} />
          <Column gap={2} weight={1}>
            <Text text={m["title"]} font={:display} text_size={18} text_color={:on_surface} />
            <Text text={m["ref"]} text_size={12} text_color={:muted} />
          </Column>
          {sign}
        </Row>
        <Column
          :if={open?}
          gap={6}
          padding_left={54}
          padding_right={16}
          padding_bottom={14}
          fill_width={true}
        >
          {points}
        </Column>
      </Column>
    </Box>
    """
  end

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Handles a Workshop event."
  def handle({:starter, label}, socket),
    do: {:noreply, Socket.assign(socket, desc: label <> ": ", build: nil)}

  def handle({:open_tool, id}, socket), do: {:noreply, Helpers.open_tool(socket, id)}

  def handle(:build, socket) do
    desc =
      case String.trim(socket.assigns.desc) do
        "" ->
          "A sermon outline helper: give it a passage, it drafts a big idea and three movements I can edit."

        text ->
          text
      end

    screen = self()
    conversation_id = socket.assigns.conversation.id
    model_id = socket.assigns.model_id

    {:noreply,
     socket
     |> Socket.assign(desc: desc, build: {:step, 0})
     |> Socket.start_async(:build, fn ->
       Workshop.build(desc, conversation_id, model_id, &send(screen, {:build_step, &1}))
     end)}
  end

  @doc "A build step started (sent by the build task)."
  def step(i, socket) do
    case socket.assigns.build do
      {:step, _} -> Socket.assign(socket, :build, {:step, i})
      _ -> socket
    end
  end

  @doc """
  The build finished (`handle_async(:build, ...)`). In the Workshop the new
  tool opens; anywhere else the user stays put and a toast says it's ready.
  """
  def built({:ok, {:ok, tool}}, socket) do
    socket = Socket.assign(socket, build: nil, desc: "")

    if socket.assigns.tab == :workshop,
      do: Helpers.open_tool(socket, tool.id),
      else: Helpers.toast(socket, "#{tool.name} is built. It’s in the Workshop.")
  end

  def built({:ok, {:error, reason}}, socket), do: Socket.assign(socket, :build, {:failed, reason})

  def built({:exit, _}, socket),
    do: Socket.assign(socket, :build, {:failed, "The build stopped before it finished."})

  @doc "Handles an event on a built tool."
  def handle_tool({:move, i}, socket),
    do:
      {:noreply,
       Socket.assign(socket, :move_open, if(socket.assigns.move_open == i, do: -1, else: i))}

  def handle_tool(:discuss, socket) do
    conversation =
      Library.get_conversation(socket.assigns.tool.conversation_id) ||
        socket.assigns.conversation

    {:noreply, Helpers.open_conversation(socket, conversation)}
  end

  def handle_tool(:change, socket) do
    {:noreply,
     socket
     |> Socket.assign(desc: socket.assigns.tool.description, build: nil)
     |> Helpers.go(:workshop)}
  end
end
