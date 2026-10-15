defmodule Bezalel.AppScreen do
  @moduledoc """
  The app: Study, Conversations, Workshop (and a built tool) and Settings
  under one top bar and tab bar, with the sheets and the toast over them.
  Each tab's view and events live in `Bezalel.Views.*`; this screen holds the
  state and routes events to them.
  """
  use Mob.Screen

  alias Bezalel.{Account, Library, Settings}
  alias Bezalel.Views.{Conversations, Helpers, Sheets, Study, Workshop}
  alias Bezalel.Views.Settings, as: SettingsView
  alias Mob.Theme.AdaptiveWatcher
  alias MobBezalel.{Palette, UI}
  alias Rho.Auth.Login

  @tabs [
    {:study, "Study", :study},
    {:convs, "Conversations", :conversations},
    {:workshop, "Workshop", :workshop},
    {:settings, "Settings", :settings}
  ]

  def mount(_params, _session, socket) do
    mode = Settings.mode()
    Mob.Theme.set(Settings.theme_module(mode))
    AdaptiveWatcher.register_adaptive(MobBezalel.System)
    # System mode: re-set the theme on an OS light/dark flip so this screen
    # repaints in the new palette (the watcher updates the theme only).
    Mob.Device.subscribe(:appearance)
    # Sign-ins, API keys and usage change from here and from model calls:
    # Settings follows both. A sign-in started before this screen
    # (re)started reports here from now on.
    :ok = Rho.Auth.subscribe()
    :ok = Rho.Usage.subscribe()
    login = Login.pending()

    conversation = Library.get_conversation(Settings.conversation_id()) || Library.seed!()

    socket =
      socket
      |> Mob.Socket.assign(
        mode: mode,
        cover: Settings.cover(),
        model_id: Settings.model(),
        account: Account.status(),
        usage: Account.usage(),
        login: login,
        login_code: "",
        key_drafts: %{},
        sheet: nil,
        toast: nil,
        draft: "",
        desc: "",
        build: nil,
        tool: nil,
        tools: [],
        shelf: [],
        shelf_done: true,
        counts: %{conversations: 0, tools: 0},
        replying: %{},
        switched: false,
        move_open: 0
      )
      |> Helpers.open_conversation(conversation)

    {:ok, socket}
  end

  def render(assigns) do
    sa = assigns[:safe_area] || %{top: 0, bottom: 0}
    tabs = for {key, label, icon} <- @tabs, do: {label, icon, {self(), {:tab, key}}}

    ~MOB"""
    <Box align="bottom" fill_width={true} fill_height={true} background={:background}>
      <Column fill_width={true} fill_height={true} background={:background}>
        {top_bar(assigns)}
        {body(assigns)}
        {UI.tab_bar(tabs, active_index(@tab), @cover, sa.bottom)}
      </Column>
      {toast(@toast, @tab, sa.bottom)}
      {Sheets.render(assigns)}
    </Box>
    """
  end

  defp top_bar(%{tab: :study} = assigns) do
    toggle =
      UI.bar_button(
        Study.toggle_all_label(assigns),
        {self(), {:study, :toggle_all}},
        assigns.cover
      )

    UI.top_bar("Study", assigns.cover, trailing: if(assigns.messages != [], do: toggle))
  end

  defp top_bar(%{tab: :tool} = assigns) do
    back = UI.bar_button("Workshop", {self(), {:tab, :workshop}}, assigns.cover)
    UI.top_bar(assigns.tool.name, assigns.cover, trailing: back)
  end

  defp top_bar(assigns) do
    title = %{convs: "Conversations", workshop: "Workshop", settings: "Settings"}[assigns.tab]
    UI.top_bar(title, assigns.cover)
  end

  defp body(%{tab: :study} = assigns), do: Study.render(assigns)
  defp body(%{tab: :convs} = assigns), do: Conversations.render(assigns)
  defp body(%{tab: :workshop} = assigns), do: Workshop.render(assigns)
  defp body(%{tab: :tool} = assigns), do: Workshop.render_tool(assigns)
  defp body(%{tab: :settings} = assigns), do: SettingsView.render(assigns)

  defp active_index(:tool), do: 2
  defp active_index(tab), do: Enum.find_index(@tabs, fn {key, _, _} -> key == tab end)

  # Sits above the composer in Study, above the tab bar elsewhere; on iOS the
  # root runs under the home indicator, so that inset is added there.
  defp toast(nil, _tab, _inset), do: []

  defp toast(toast, tab, inset) do
    bottom = if tab == :study, do: 150, else: 78
    ios = %{padding_bottom: bottom + inset}
    o = Palette.overlay()

    actions =
      for {show?, label, tag} <- [
            {toast.ask_again, "Ask again", :ask_again},
            {toast.undo != nil, "Undo", :undo}
          ],
          show? do
        tap = {self(), {:study, tag}}
        ~MOB(<Text
  text={label}
  font={:ui_semibold}
  text_size={13}
  text_color={o.popover_action}
  padding={4}
  on_tap={tap}
/>)
      end

    ~MOB"""
    <Box padding_left={16} padding_right={16} padding_bottom={bottom} ios={ios} fill_width={true}>
      <Box
        background={o.popover}
        corner_radius={16}
        padding_left={16}
        padding_right={16}
        padding_top={12}
        padding_bottom={12}
        fill_width={true}
      >
        <Row gap={12} align={:center} fill_width={true}>
          <Text
            text={toast.text}
            font={:ui_medium}
            text_size={13}
            text_color={o.on_popover}
            weight={1}
          />
          {actions}
        </Row>
      </Box>
    </Box>
    """
  end

  # ── Events ────────────────────────────────────────────────────────────────

  def handle_info({:tap, {:tab, tab}}, socket) do
    {:noreply, socket |> Mob.Socket.assign(sheet: nil, menu: nil) |> Helpers.go(tab)}
  end

  def handle_info({:tap, {:study, event}}, socket), do: Study.handle(event, socket)
  def handle_info({:tap, {:convs, event}}, socket), do: Conversations.handle(event, socket)
  def handle_info({:tap, {:workshop, event}}, socket), do: Workshop.handle(event, socket)
  def handle_info({:tap, {:tool, event}}, socket), do: Workshop.handle_tool(event, socket)
  def handle_info({:tap, {:settings, event}}, socket), do: SettingsView.handle(event, socket)

  # The notice in Study ("Now answering with …") shows after any change of
  # model, whichever tab it was made from, until the conversation changes.
  def handle_info({:tap, {:model, id}}, socket) do
    Settings.put_model(id)
    switched = id != socket.assigns.model_id

    {:noreply,
     Mob.Socket.assign(socket,
       model_id: id,
       sheet: nil,
       switched: switched or socket.assigns.switched
     )}
  end

  def handle_info({:tap, :sheet}, socket), do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:dismiss, :sheet}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :sheet, nil)}

  def handle_info({:change, :draft, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :draft, value)}

  def handle_info({:change, :desc, value}, socket),
    do: {:noreply, Mob.Socket.assign(socket, :desc, value)}

  def handle_info({:change, {:settings, field}, value}, socket),
    do: {:noreply, SettingsView.change(field, value, socket)}

  def handle_info({:rho_auth, :changed}, socket), do: {:noreply, SettingsView.refresh(socket)}

  def handle_info({:rho_usage, :changed}, socket),
    do: {:noreply, SettingsView.refresh_usage(socket)}

  def handle_info({:rho_login, provider, result}, socket),
    do: {:noreply, SettingsView.login_result(provider, result, socket)}

  def handle_info({:build_step, i}, socket), do: {:noreply, Workshop.step(i, socket)}

  def handle_info({:toast_expire, ref}, socket) do
    case socket.assigns.toast do
      %{ref: ^ref} -> {:noreply, Mob.Socket.assign(socket, :toast, nil)}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:mob_device, :color_scheme_changed, _scheme}, socket) do
    if socket.assigns.mode == :system, do: Mob.Theme.set(MobBezalel.System)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  def handle_async({:reply, conversation_id, _ref}, result, socket),
    do: {:noreply, Study.replied(conversation_id, result, socket)}

  def handle_async(:build, result, socket), do: {:noreply, Workshop.built(result, socket)}
end
