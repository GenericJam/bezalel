defmodule Bezalel.Workshop.Host do
  @moduledoc """
  The process a built tool's screen (a Dyn screen, `Bezalel.Workshop.Screens`)
  runs in while its panel is open, after Operator's front host
  (`Operator.Core.Front.Host`), reduced to one screen.

  The app's screen (`Bezalel.AppScreen`) starts one per open panel
  (monitored, not linked) and only ever gets plain data from it: the
  screen's `mount/3`, `handle_info/2` and `render/1` run here, never in the
  app's screen process, so a screen that raises or exits stops this
  process only, and the panel says so. Its crash counts against the
  screen's generation: the compiled `mount/3` registers the process with
  the Keeper (`Rho.Dyn.Compiler`), which reverts a generation on probation
  after its third crash within a minute.

  Nothing the screen made runs its code anywhere else:

    * A crash is described by the host: an exception's `message/1` (Dyn
      code) runs in a helper the host starts for it
      (`Rho.Untrusted.format/4`: at most a second, 600 bytes and a heap
      bound; it never ends in a crash report and dies with the host; else
      the exception is described without protocols), and the host exits
      with `{:rho_crash, text}`, so the Keeper reports that text and
      `outcome/1` reads it; any other exit reason is described without
      calling Dyn code.
    * The view is plain data: structs other than `%Mob.Style{}` are sent
      as maps, so no Dyn protocol implementation (`Inspect`, `String.Chars`)
      runs while the app draws it. It is rendered here first against a
      stand-in for the native layer, so a view Mob can't draw, or one with
      more than 2048 controls (the app's frame holds 4096 tap handles,
      its own controls included), crashes this process instead of the app's
      frame.

  Each changed view goes to the owner as `{Bezalel.Workshop.Host, pid,
  {:view, tree}}`, with composites and lists expanded here (`Mob.Composite`,
  `Mob.List`), so the view's events (`on_tap={{self(), tag}}` in the
  screen's `render/1`) come straight to this process. Navigation a screen
  asks for is ignored.

  Only nodes native draws on both platforms that need nothing more from the
  app's screen get through (layout, text, controls, images, icons, lazy
  lists, canvases); anything else (web views, videos, camera previews,
  native views, GPU views, sheets and overlays, lists or composites left
  unexpanded) is replaced by a note. So a panel isn't meant to reach the
  network or show web content (built tools are written to work offline), and an image's `src` (or
  any `url`, also in a platform block, a style or under a string key) is
  kept only if it is an on-phone path or a `plugin://` asset. Anything with
  a scheme (`http:`, `https:`, `ftp:`, `data:`, `file:`, ...) is dropped,
  atoms included (they reach native as their names): Mob's image views
  fetch `http(s)`, and neither platform decodes a `data:` URL, so allowing
  those would only open a way out.
  """

  @stop_ms 2_000
  # How long a crash's description (the screen's `message/1`) may take.
  @describe_ms 1_000
  # Tap handles a panel may take of the app's frame (4096 in all).
  @max_taps 2048

  # Nodes a panel draws: what native draws on both platforms with nothing
  # more from the app's screen.
  @drawn ~w(column row wrap box scroll text button text_field toggle slider divider spacer
            progress image icon lazy_list canvas)a

  # Props a node fetches from (images and videos read `src`, web views `url`).
  @fetched [:src, "src", :url, "url"]

  @doc """
  Starts a host for screen `module`, mounted with `assigns` (`:size_class`,
  `:safe_area`) on `platform`, painting to `owner`, which it doesn't
  outlive: a watcher kills it when the owner exits, even while it is busy
  in screen code (an exit the screen can't trap, not counted as a crash).
  Returns `{pid, monitor}`.
  """
  @spec start(pid(), module(), atom(), map()) :: {pid(), reference()}
  def start(owner, module, platform, assigns) do
    {host, ref} = spawn_monitor(fn -> run(owner, module, platform, assigns) end)
    spawn(fn -> watch(owner, host) end)
    {host, ref}
  end

  defp watch(owner, host) do
    owner_ref = Process.monitor(owner)
    host_ref = Process.monitor(host)

    receive do
      {:DOWN, ^owner_ref, :process, _, _} ->
        :ok = Rho.Dyn.unwatch(host)
        Process.exit(host, :kill)

      {:DOWN, ^host_ref, :process, _, _} ->
        :ok
    end
  end

  @doc """
  Stops a host (an orderly exit, not a crash). A host still busy in screen
  code after #{@stop_ms} ms is killed, which counts as its screen's crash.
  Returns at once.
  """
  @spec stop(pid()) :: :ok
  def stop(host) when is_pid(host) do
    send(host, {__MODULE__, :stop})

    spawn(fn ->
      ref = Process.monitor(host)

      receive do
        {:DOWN, ^ref, :process, ^host, _} -> :ok
      after
        @stop_ms -> Process.exit(host, :kill)
      end
    end)

    :ok
  end

  @doc """
  What the panel shows after its host exited with `reason`: `nil` for an
  orderly exit, `{:crashed, text}` otherwise. Never calls the screen's
  code: a reason the host didn't describe itself (a link's exit, a kill)
  is described without protocols (`Rho.Untrusted.exit_text/2`).
  """
  @spec outcome(term()) :: nil | {:crashed, String.t()}
  def outcome(:normal), do: nil
  def outcome(:shutdown), do: nil
  def outcome({:shutdown, _}), do: nil
  # The text is the screen's to choose (it can exit with this reason itself):
  # capped and made valid UTF-8 like any other.
  def outcome({:rho_crash, text} = reason) when is_binary(text),
    do: {:crashed, Rho.Untrusted.exit_text(reason, 600)}

  def outcome(:killed), do: {:crashed, "It was stopped: it didn't answer."}
  def outcome(reason), do: {:crashed, "It exited: " <> Rho.Untrusted.exit_text(reason, 600)}

  defp run(owner, module, platform, assigns) do
    s = %{owner: owner, owner_ref: Process.monitor(owner), module: module, last: nil}
    s |> Map.put(:socket, mount(module, platform, assigns)) |> paint() |> loop()
  catch
    :exit, reason when reason in [:normal, :shutdown] ->
      exit(reason)

    :exit, {:shutdown, _} ->
      exit(:shutdown)

    # Outside the app's processes: `message/1` is the screen's code, run
    # in a bounded helper of this process's.
    kind, reason ->
      text =
        Rho.Untrusted.format(kind, reason, __STACKTRACE__, max: 600, timeout_ms: @describe_ms)

      exit({:rho_crash, text})
  end

  defp loop(s) do
    receive do
      {__MODULE__, :stop} ->
        :ok

      {:DOWN, ref, :process, _owner, _reason} when ref == s.owner_ref ->
        :ok

      message ->
        s |> handle(message) |> paint() |> loop()
    end
  end

  defp mount(module, platform, assigns) do
    socket =
      module
      |> Mob.Socket.new(platform: platform)
      |> Mob.Socket.assign(
        size_class: assigns[:size_class] || Mob.SizeClass.placeholder(),
        safe_area: assigns[:safe_area] || %{top: 0, bottom: 0, left: 0, right: 0}
      )

    case module.mount(%{}, %{}, socket) do
      {:ok, %Mob.Socket{} = socket} -> socket
      other -> raise "#{inspect(module)}.mount/3 must return {:ok, socket}, got: #{short(other)}"
    end
  end

  defp handle(%{module: module, socket: socket} = s, message) do
    case module.handle_info(message, socket) do
      {:noreply, %Mob.Socket{} = socket} ->
        %{s | socket: Mob.Socket.put_mob(socket, :nav_action, nil)}

      other ->
        raise "#{inspect(module)}.handle_info/2 must return {:noreply, socket}, got: " <>
                short(other)
    end
  end

  # Sent only when it changed (the theme counts: a theme switch redraws).
  defp paint(%{module: module, socket: socket} = s) do
    tree =
      socket.assigns
      |> module.render()
      |> Mob.Composite.expand(self())
      |> Mob.List.expand(Map.get(socket.__mob__, :list_renderers, %{}), self())
      |> panel_tree()

    hash = :erlang.phash2({tree, Mob.Theme.current()})

    if hash == s.last do
      s
    else
      {:ok, :json_tree} = Mob.Renderer.render(tree, socket.__mob__.platform, __MODULE__.DryRun)
      taps = __MODULE__.DryRun.taps()

      if taps > @max_taps,
        do: raise("its view has #{taps} controls; a tool's panel holds at most #{@max_taps}")

      send(s.owner, {__MODULE__, self(), {:view, tree}})
      %{s | last: hash}
    end
  end

  @doc false
  # What a panel draws of a screen's (expanded) tree; see the moduledoc.
  @spec panel_tree(term()) :: term()
  def panel_tree(%{type: type, props: props, children: kids})
      when type in @drawn and is_map(props) and is_list(kids) do
    %{
      type: type,
      props: props(plain(props)),
      children: kids |> List.flatten() |> Enum.map(&panel_tree/1)
    }
  end

  def panel_tree(%{type: type, props: _, children: _}) when is_atom(type),
    do: %{
      type: :text,
      props: %{text: "(this view can't be drawn in a tool's panel)", text_color: :muted},
      children: []
    }

  def panel_tree(other), do: plain(other)

  # `props` is plain data (`plain/1`): a struct is a map by now, so no block
  # escapes the filter by being one.
  defp props(props) when is_map(props) do
    for {key, value} <- props, kept?(key, value), into: %{}, do: {key, prop(key, value)}
  end

  defp kept?(key, value) when key in @fetched, do: on_phone?(value)
  defp kept?(_key, _value), do: true

  # Platform blocks and styles are merged into the props when drawn.
  defp prop(key, %{} = value) when key in [:ios, :android], do: props(value)
  defp prop(:style, %Mob.Style{props: props}), do: %Mob.Style{props: props(props)}
  defp prop(_key, value), do: value

  # Atoms reach native as their names (`:json.encode/1`).
  defp on_phone?(src) when src in [nil, true, false], do: true
  defp on_phone?(src) when is_atom(src), do: src |> Atom.to_string() |> on_phone?()
  defp on_phone?("plugin://" <> _), do: true
  defp on_phone?(src) when is_binary(src), do: not String.contains?(src, ":")
  defp on_phone?(_src), do: false

  # Plain data: structs become maps, except `%Mob.Style{}` (with plain props).
  defp plain(%Mob.Style{props: props}), do: %Mob.Style{props: plain(props)}
  defp plain(%_{} = struct), do: struct |> Map.from_struct() |> plain()
  defp plain(%{} = map), do: Map.new(map, fn {k, v} -> {plain(k), plain(v)} end)
  defp plain(list) when is_list(list), do: Enum.map(list, &plain/1)

  defp plain(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> Enum.map(&plain/1) |> List.to_tuple()

  defp plain(term), do: term

  defp short(term), do: inspect(term, limit: 10, printable_limit: 200)

  defmodule DryRun do
    @moduledoc false
    # The native layer's calls `Mob.Renderer.render/3` makes: the host renders
    # a view here first so one Mob can't draw fails in the host, not in the
    # app's frame. Counts the tap handles a frame would take (`taps/0`) and,
    # like the real layer, takes only targets on this node.
    def clear_taps, do: Process.put({__MODULE__, :taps}, 0) && :ok
    def set_transition(_animation), do: :ok
    def set_root(_json), do: :ok

    def register_tap(handler) do
      if Enum.any?(pids(handler), &(node(&1) != node())),
        do: raise(ArgumentError, "a tap's target is on another node")

      n = taps()
      Process.put({__MODULE__, :taps}, n + 1)
      n
    end

    def taps, do: Process.get({__MODULE__, :taps}, 0)

    defp pids(pid) when is_pid(pid), do: [pid]
    defp pids(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.flat_map(&pids/1)
    defp pids(_other), do: []
  end
end
