defmodule Bezalel.Views.Conversations do
  @moduledoc "The Conversations tab: a shelf of studies, one open at a time."
  import Mob.Sigil

  alias Bezalel.Library
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.UI

  @page 30

  @doc """
  Loads the shelf: the first page on entering the tab, or as many rows as
  are already paged in when something changed underneath it.
  """
  def load(socket) do
    limit = max(length(socket.assigns.shelf), @page)
    shelf = Library.list_conversations(limit: limit)
    Socket.assign(socket, shelf: shelf, shelf_done: length(shelf) < limit)
  end

  @doc "The Conversations body: a lazy list, paged in as it scrolls."
  def render(assigns) do
    rows = Enum.map(assigns.shelf, &row(&1, assigns.conversation.id))
    new_tap = {self(), {:convs, :new}}
    more = {self(), {:convs, :more}}

    ~MOB"""
    <LazyList weight={1} background={:background} on_end_reached={more}>
      <Column
        id="shelf-head"
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={8}
        gap={14}
        fill_width={true}
      >
        <Row align={:center} fill_width={true}>
          <Text
            text="Conversations"
            font={:display}
            text_size={30}
            text_color={:on_background}
            weight={1}
          />
          {UI.pill_button("New", new_tap, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        <Text
          text="Each week’s prep gets its own conversation. Shelve it when you’re done; pull it back out whenever you need it."
          text_size={13}
          line_height={1.5}
          text_color={:muted}
        />
      </Column>
      {rows}
    </LazyList>
    """
  end

  defp row(%{conversation: c, message_count: n}, open_id) do
    open? = c.id == open_id

    {border, state, state_color} =
      if open?, do: {:secondary, "OPEN", :secondary}, else: {:border, "SHELVED", :muted}

    meta = "#{c.kind} · #{Helpers.count(n, "message")}"
    tap = {self(), {:convs, {:open, c.id}}}
    id = "conversation-#{c.id}"

    ~MOB"""
    <Box
      id={id}
      padding_left={18}
      padding_right={18}
      padding_top={7}
      padding_bottom={7}
      fill_width={true}
    >
      <Box
        background={:surface}
        border_color={border}
        border_width={1.5}
        corner_radius={18}
        padding={14}
        fill_width={true}
        on_tap={tap}
      >
        <Row gap={14} align={:center} fill_width={true}>
          <Column gap={3} weight={1}>
            {UI.kicker(Helpers.when_label(c.inserted_at))}
            <Text text={c.name} font={:display} text_size={18} text_color={:on_surface} />
            <Text text={meta} text_size={12} text_color={:muted} />
          </Column>
          {UI.kicker(state, state_color)}
        </Row>
      </Box>
    </Box>
    """
  end

  @doc "Handles a Conversations event."
  def handle(:more, %{assigns: %{shelf_done: true}} = socket), do: {:noreply, socket}

  def handle(:more, socket) do
    page = Library.list_conversations(limit: @page, offset: length(socket.assigns.shelf))

    {:noreply,
     Socket.assign(socket,
       shelf: socket.assigns.shelf ++ page,
       shelf_done: length(page) < @page
     )}
  end

  def handle({:open, id}, socket) do
    case Library.get_conversation(id) do
      nil -> {:noreply, socket}
      c -> {:noreply, Helpers.open_conversation(socket, c)}
    end
  end

  def handle(:new, socket) do
    {:ok, c} = Library.create_conversation(%{name: "New study", kicker: "STUDY", kind: "Study"})
    {:noreply, Helpers.open_conversation(socket, c)}
  end
end
