defmodule Bezalel.Views.Settings do
  @moduledoc "The Settings tab: account, appearance, model, usage, what's on the phone."
  import Mob.Sigil

  alias Bezalel.{Agent, Models, Settings}
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.{Palette, UI}

  @doc "The Settings body."
  def render(assigns) do
    model = Models.get(assigns.model_id)
    mode_index = Enum.find_index(Settings.modes(), &(&1 == assigns.mode))
    cover_index = Enum.find_index(Settings.covers(), &(&1 == assigns.cover))
    mode_opts = for m <- Settings.modes(), do: {label(m), {self(), {:settings, {:mode, m}}}}
    cover_opts = for c <- Settings.covers(), do: {label(c), {self(), {:settings, {:cover, c}}}}
    models_tap = {self(), {:settings, :models}}
    gallery_tap = {self(), {:settings, :gallery}}

    system_note =
      if assigns.mode == :system,
        do: "Follows your phone: #{MobBezalel.mode() || :dark} right now.",
        else: nil

    model_note =
      if Agent.live?(),
        do: nil,
        else: "Replies come from the design’s script until a model is connected."

    appearance =
      UI.card(
        [
          ~MOB(<Text text="Theme" font={:ui_medium} text_size={14} text_color={:on_surface} />),
          UI.segmented(mode_opts, mode_index),
          note(system_note),
          ~MOB(<Text text="Cover" font={:ui_medium} text_size={14} text_color={:on_surface} />),
          UI.segmented(cover_opts, cover_index)
        ],
        padding: 16,
        gap: 10
      )

    usage =
      UI.card(
        [
          ~MOB"""
          <Row gap={8} align={:end}>
            <Text text="0" font={:display} text_size={30} text_color={:on_surface} />
            <Text text="tokens" text_size={12} text_color={:muted} />
          </Row>
          """,
          ~MOB(<Text
  text="No model calls yet. Usage per model shows here once a model answers."
  text_size={13}
  line_height={1.45}
  text_color={:muted}
/>)
        ],
        padding: 16,
        gap: 8
      )

    on_phone =
      UI.card(
        [
          device_row("Conversations", "#{assigns.counts.conversations} stored", true),
          device_row("Tools", "#{assigns.counts.tools} built", true),
          device_row("Bible text (BSB)", "Exodus 31 sample", false)
        ],
        padding: 0,
        gap: 0
      )

    sections = [
      section("Account", [account(assigns)]),
      section("Appearance", [appearance]),
      section("Model", [model_row(model, models_tap), note(model_note)]),
      section("Token usage · this week", [usage]),
      section("On this phone", [on_phone]),
      section("Design", [
        UI.pill_button("Design specimen", gallery_tap, :outline,
          height: 40,
          fill: false,
          text_size: 13
        )
      ])
    ]

    ~MOB"""
    <Scroll weight={1} background={:background}>
      <Column
        padding_left={18}
        padding_right={18}
        padding_top={22}
        padding_bottom={28}
        gap={18}
        fill_width={true}
      >
        <Text text="Settings" font={:display} text_size={30} text_color={:on_background} />
        {sections}
      </Column>
    </Scroll>
    """
  end

  defp note(nil), do: []

  defp note(text),
    do: ~MOB(<Text text={text} text_size={12} line_height={1.45} text_color={:muted} />)

  defp section(title, children) do
    ~MOB"""
    <Column gap={8} fill_width={true}>
      {UI.kicker(title)}
      {children}
    </Column>
    """
  end

  defp account(%{signed_in: true}) do
    out = {self(), {:settings, :sign_out}}

    UI.card(
      ~MOB"""
      <Row gap={12} align={:center} fill_width={true}>
        <Box
          width={40}
          height={40}
          corner_radius={20}
          background={Palette.brand().umber}
          align="center"
          fill_width={false}
        >
          <Text text="B" font={:display} text_size={18} text_color={Palette.overlay().mark_gold} />
        </Box>
        <Column gap={2} weight={1}>
          <Text text="Signed in" font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Text text="Through the browser" text_size={12} text_color={:muted} />
        </Column>
        {UI.pill_button("Sign out", out, :outline, height: 36, fill: false, text_size: 13)}
      </Row>
      """,
      padding: 14
    )
  end

  defp account(_assigns) do
    tap = {self(), {:settings, :sign_in}}

    UI.card(
      [
        ~MOB(<Text
  text="Sign in with your model provider through the browser. Not built yet: it comes with the model connection."
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>),
        UI.pill_button("Sign in with browser", tap, :outline)
      ],
      padding: 14,
      gap: 10
    )
  end

  defp model_row(model, tap) do
    ~MOB"""
    <Box
      background={:surface}
      border_color={:border}
      border_width={1}
      corner_radius={18}
      padding_left={16}
      padding_right={16}
      padding_top={10}
      padding_bottom={10}
      fill_width={true}
      on_tap={tap}
    >
      <Row gap={12} align={:center} fill_width={true}>
        <Box width={10} height={10} corner_radius={5} background={model.dot} fill_width={false} />
        <Column gap={2} weight={1}>
          <Text text={model.name} font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Text text={model.note} text_size={12} text_color={:muted} />
        </Column>
        <Text text="Change" font={:ui_medium} text_size={13} text_color={:secondary} />
      </Row>
    </Box>
    """
  end

  defp device_row(k, v, rule?) do
    row = ~MOB"""
    <Row align={:center} height={48} padding_left={16} padding_right={16} fill_width={true}>
      <Text text={k} text_size={14} text_color={:on_surface} weight={1} />
      <Text text={v} text_size={14} text_color={:muted} />
    </Row>
    """

    if rule?, do: [row, ~MOB(<Divider color={:border} />)], else: [row]
  end

  defp label(atom), do: atom |> Atom.to_string() |> String.capitalize()

  # ── Events ────────────────────────────────────────────────────────────────

  @doc "Handles a Settings event."
  def handle({:mode, mode}, socket) do
    Settings.put_mode(mode)
    Mob.Theme.set(Settings.theme_module(mode))
    {:noreply, Socket.assign(socket, :mode, mode)}
  end

  def handle({:cover, cover}, socket) do
    Settings.put_cover(cover)
    {:noreply, Socket.assign(socket, :cover, cover)}
  end

  def handle(:models, socket), do: {:noreply, Socket.assign(socket, :sheet, :models)}

  # Browser sign-in needs a provider connection; until then it says so
  # rather than pretending to sign in.
  def handle(:sign_in, socket),
    do:
      {:noreply, Helpers.toast(socket, "Sign-in comes with the model connection. Not built yet.")}

  def handle(:sign_out, socket) do
    Settings.put_signed_in(false)
    {:noreply, Socket.assign(socket, :signed_in, false)}
  end

  def handle(:gallery, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.DesignGalleryScreen)}
end
