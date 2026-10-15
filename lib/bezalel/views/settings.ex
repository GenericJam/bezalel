defmodule Bezalel.Views.Settings do
  @moduledoc "The Settings tab: account, appearance, model, usage, what's on the phone."
  import Mob.Sigil

  alias Bezalel.{Account, Agent, Models, Settings}
  alias Bezalel.Views.Helpers
  alias Mob.Socket
  alias MobBezalel.{Palette, UI}
  alias Rho.Auth
  alias Rho.Auth.Login

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

    usage = usage(assigns.usage)

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
      section("Account", account(assigns)),
      section("Appearance", [appearance]),
      section("Model", [model_row(model, assigns.account, models_tap), note(model_note)]),
      section("Token usage", [usage]),
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

  # Subscriptions (browser sign-in) in one card, API keys in another.
  defp account(assigns) do
    subscriptions =
      UI.card(
        [
          ~MOB(<Text
  text="Sign in with your model subscription. It opens in your browser and returns here."
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>)
          | Enum.map(Account.subscriptions(), &subscription(&1, assigns))
        ],
        padding: 14,
        gap: 12
      )

    keys =
      UI.card(
        [
          ~MOB(<Text
  text="Or use an API key. It stays in this phone's secure store. A provider keeps one: a key and a sign-in replace each other."
  text_size={14}
  line_height={1.5}
  text_color={:on_surface}
/>)
          | Enum.map(Account.api_keys(), &api_key(&1, assigns))
        ],
        padding: 14,
        gap: 12
      )

    [subscriptions, keys]
  end

  defp subscription(provider, assigns) do
    name = Account.subscription_name(provider)

    case assigns.account[provider] do
      %{type: :oauth, email: email} ->
        out = {self(), {:settings, {:sign_out, provider}}}
        who = email || "#{name} subscription"
        initial = who |> String.first() |> String.upcase()

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
            <Text
              text={initial}
              font={:display}
              text_size={18}
              text_color={Palette.overlay().mark_gold}
            />
          </Box>
          <Column gap={2} weight={1}>
            <Text text={who} font={:ui_medium} text_size={15} text_color={:on_surface} />
            <Text text={name <> " · signed in through the browser"} text_size={12} text_color={:muted} />
          </Column>
          {UI.pill_button("Sign out", out, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        """

      _ ->
        tap = {self(), {:settings, {:sign_in, provider}}}

        what =
          cond do
            match?(%{type: :api_key}, assigns.account[provider]) ->
              "Signing in replaces your #{Account.key_name(provider)} key"

            provider == :anthropic ->
              "Pro or Max subscription"

            true ->
              "Plus or Pro subscription"
          end

        row = ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Column gap={2} weight={1}>
            <Text text={name} font={:ui_medium} text_size={15} text_color={:on_surface} />
            <Text text={what} text_size={12} text_color={:muted} />
          </Column>
          {UI.pill_button("Sign in", tap, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        """

        [row | pending(provider, assigns)]
    end
  end

  # While a sign-in waits for the browser. Claude's page may show a code
  # instead of coming back: it goes in the field.
  defp pending(provider, %{login: provider} = assigns) when provider == :anthropic do
    change = {self(), {:settings, :login_code}}
    use_tap = {self(), {:settings, :paste_code}}

    [
      note("Finish in the browser. If the page shows a code instead, paste it here."),
      ~MOB"""
      <Row gap={8} align={:center} fill_width={true}>
        <TextField
          value={@login_code}
          placeholder="Paste the code"
          on_change={change}
          background={:background}
          border_color={:border}
          border_width={1}
          text_size={14}
          weight={1}
        />
        {UI.pill_button("Use code", use_tap, :primary, height: 40, fill: false, text_size: 13)}
      </Row>
      """
    ]
  end

  defp pending(provider, %{login: provider}),
    do: [note("Finish in the browser; it returns here.")]

  defp pending(_provider, _assigns), do: []

  defp api_key(provider, assigns) do
    name = Account.key_name(provider)

    case assigns.account[provider] do
      %{type: :api_key, masked: masked} ->
        remove = {self(), {:settings, {:remove_key, provider}}}

        ~MOB"""
        <Row gap={12} align={:center} fill_width={true}>
          <Column gap={2} weight={1}>
            <Text text={name <> " key"} font={:ui_medium} text_size={15} text_color={:on_surface} />
            <Text text={masked} text_size={12} text_color={:muted} />
          </Column>
          {UI.pill_button("Remove", remove, :outline, height: 36, fill: false, text_size: 13)}
        </Row>
        """

      _ ->
        change = {self(), {:settings, {:key, provider}}}
        save = {self(), {:settings, {:save_key, provider}}}
        value = Map.get(assigns.key_drafts, provider, "")

        ~MOB"""
        <Column gap={6} fill_width={true}>
          <Text text={name <> " key"} font={:ui_medium} text_size={15} text_color={:on_surface} />
          <Row gap={8} align={:center} fill_width={true}>
            <TextField
              value={value}
              placeholder="Paste your key"
              on_change={change}
              secure={true}
              background={:background}
              border_color={:border}
              border_width={1}
              text_size={14}
              weight={1}
            />
            {UI.pill_button("Save", save, :outline, height: 40, fill: false, text_size: 13)}
          </Row>
        </Column>
        """
    end
  end

  defp usage([]) do
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
  end

  defp usage(rows) do
    total = rows |> Enum.map(& &1.total) |> Enum.sum()
    today = rows |> Enum.map(& &1.today) |> Enum.sum()

    across =
      case rows do
        [_] -> "tokens across 1 model"
        _ -> "tokens across #{length(rows)} models"
      end

    per_model =
      for r <- rows do
        {name, dot} = usage_label(r.model)
        figures = "#{tokens(r.today)} today · #{tokens(r.total)}"

        ~MOB"""
        <Column gap={5} fill_width={true}>
          <Row fill_width={true}>
            <Text text={name} font={:ui_medium} text_size={13} text_color={:on_surface} weight={1} />
            <Text text={figures} text_size={13} text_color={:muted} />
          </Row>
          {UI.meter(if(total > 0, do: r.total / total, else: 0.0), dot)}
        </Column>
        """
      end

    UI.card(
      [
        ~MOB"""
        <Row gap={8} align={:end}>
          <Text text={tokens(total)} font={:display} text_size={30} text_color={:on_surface} />
          <Text text={across} text_size={12} text_color={:muted} />
        </Row>
        """,
        note("#{tokens(today)} today")
        | per_model
      ],
      padding: 16,
      gap: 12
    )
  end

  # Usage is kept under the spec a call used: the catalog's name for it, or
  # the spec itself for a model the catalog no longer lists.
  defp usage_label(spec) do
    case Models.lookup(spec) do
      %{name: name, dot: dot} ->
        {name, dot}

      nil ->
        provider =
          case Auth.provider_for_model(spec) do
            {:ok, provider} -> provider
            :error -> nil
          end

        {spec, Models.dot(provider) || :muted}
    end
  end

  @doc "A token count as Settings shows it: `950`, `12.4k`, `1.2M`."
  @spec tokens(non_neg_integer()) :: String.t()
  def tokens(n) when n < 1000, do: Integer.to_string(n)
  def tokens(n) when n < 1_000_000, do: short(n / 1000) <> "k"
  def tokens(n), do: short(n / 1_000_000) <> "M"

  defp short(x) when x >= 100, do: x |> round() |> Integer.to_string()

  defp short(x),
    do: x |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.trim_trailing(".0")

  defp model_row(model, account, tap) do
    note =
      if Models.available?(model, account),
        do: Auth.label(model.provider),
        else: "Needs your " <> Models.needs(model.provider)

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
          <Text text={note} text_size={12} text_color={:muted} />
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

  def handle({:sign_in, provider}, socket) do
    case Login.begin(provider) do
      {:ok, _url} ->
        {:noreply, Socket.assign(socket, login: provider, login_code: "")}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, begin_error(reason))}
    end
  end

  def handle(:paste_code, socket) do
    case Login.paste(:anthropic, socket.assigns.login_code) do
      :ok ->
        {:noreply,
         socket
         |> Socket.assign(login: nil, login_code: "")
         |> Helpers.toast("Checking the code with Claude…")}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, paste_error(reason))}
    end
  end

  def handle({:sign_out, provider}, socket), do: {:noreply, forget(socket, provider)}
  def handle({:remove_key, provider}, socket), do: {:noreply, forget(socket, provider)}

  def handle({:save_key, provider}, socket) do
    key = socket.assigns.key_drafts |> Map.get(provider, "") |> String.trim()
    name = Account.key_name(provider)

    with false <- key == "",
         :ok <- Auth.put_api_key(provider, key) do
      {:noreply,
       socket
       |> Socket.assign(:key_drafts, Map.delete(socket.assigns.key_drafts, provider))
       |> refresh()
       |> Helpers.toast("#{name} key saved.")}
    else
      true ->
        {:noreply, Helpers.toast(socket, "Paste your #{name} key first.")}

      {:error, reason} ->
        {:noreply, Helpers.toast(socket, "Couldn't save the key: #{Auth.describe_error(reason)}")}
    end
  end

  def handle(:gallery, socket),
    do: {:noreply, Socket.push_screen(socket, Bezalel.DesignGalleryScreen)}

  @doc "Handles typing in a Settings field: an API key, or Claude's sign-in code."
  def change({:key, provider}, value, socket),
    do: Socket.assign(socket, :key_drafts, Map.put(socket.assigns.key_drafts, provider, value))

  def change(:login_code, value, socket), do: Socket.assign(socket, :login_code, value)

  @doc """
  A sign-in finished (`{:rho_login, provider, result}` from
  `Rho.Auth.Login`): Settings shows the new account, or why it failed.
  """
  def login_result(provider, :ok, socket) do
    socket
    |> Socket.assign(login: nil, login_code: "")
    |> refresh()
    |> Helpers.toast("Signed in to #{Account.subscription_name(provider)}.")
  end

  def login_result(_provider, {:error, message}, socket) do
    socket
    |> Socket.assign(login: nil, login_code: "")
    |> Helpers.toast("Sign-in failed: #{message}")
  end

  @doc "Re-reads the sign-ins and API keys (after a change here or anywhere)."
  def refresh(socket), do: Socket.assign(socket, :account, Account.status())

  @doc "Re-reads the token usage."
  def refresh_usage(socket), do: Socket.assign(socket, :usage, Account.usage())

  # Sign-out and key removal: the provider's one credential goes.
  defp forget(socket, provider) do
    case Auth.delete(provider) do
      :ok ->
        refresh(socket)

      {:error, reason} ->
        Helpers.toast(socket, "Couldn't remove it: #{Auth.describe_error(reason)}")
    end
  end

  # The sign-in listens on the provider's fixed localhost port; another
  # app's sign-in in progress can hold it.
  defp begin_error({:listen, _port, :eaddrinuse}),
    do: "Another app is signing in right now. Finish or close that sign-in, then try again."

  defp begin_error(_reason), do: "Couldn't start the sign-in. Try again."

  defp paste_error(:no_code), do: "Paste the code the Claude page shows."
  defp paste_error(:state_mismatch), do: "That code is from another sign-in. Tap Sign in again."
  defp paste_error(:no_login_started), do: "Tap Sign in first."
  defp paste_error({:started_for, _}), do: "Another sign-in is in progress. Tap Sign in again."
end
