defmodule Bezalel.Workshop.Host do
  @moduledoc """
  The process a built tool's screen (a Dyn screen, `Bezalel.Workshop.Screens`)
  runs in while its panel is open, after Operator's front host
  (`Operator.Core.Front.Host`), reduced to one screen.

  The app's screen (`Bezalel.AppScreen`) starts one per open panel
  (monitored, not linked) and only ever gets data from it: the screen's
  `mount/3`, `handle_info/2` and `render/1` run here, never in the app's
  screen process, so a screen that raises or exits stops this process
  only, and the panel says so. Its crash counts against the screen's
  generation: the compiled `mount/3` registers the process with the Keeper
  (`Rho.Dyn.Compiler`), which reverts a generation on probation after its
  third crash within a minute.

  Each changed view goes to the owner as `{Bezalel.Workshop.Host, pid,
  {:view, tree}}`, with composites and lists expanded here (`Mob.Composite`,
  `Mob.List`), so the view's events (`on_tap={{self(), tag}}` in the
  screen's `render/1`) come straight to this process. Native views
  (components with processes of their own) aren't drawn in a panel: a note
  takes their place. Navigation a screen asks for is ignored.
  """

  @stop_ms 2_000

  @doc """
  Starts a host for screen `module`, mounted with `assigns` (`:size_class`,
  `:safe_area`) on `platform`, painting to `owner`, which it doesn't
  outlive: a watcher stops it when the owner exits, even while it is busy
  in screen code (a `:shutdown` exit, not counted as a crash). Returns
  `{pid, monitor}`.
  """
  @spec start(pid(), module(), atom(), map()) :: {pid(), reference()}
  def start(owner, module, platform, assigns) do
    {host, ref} =
      spawn_monitor(fn ->
        s = %{owner: owner, owner_ref: Process.monitor(owner), module: module, last: nil}
        s |> Map.put(:socket, mount(module, platform, assigns)) |> paint() |> loop()
      end)

    spawn(fn -> watch(owner, host) end)
    {host, ref}
  end

  defp watch(owner, host) do
    owner_ref = Process.monitor(owner)
    host_ref = Process.monitor(host)

    receive do
      {:DOWN, ^owner_ref, :process, _, _} -> Process.exit(host, :shutdown)
      {:DOWN, ^host_ref, :process, _, _} -> :ok
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
      |> without_native_views()

    hash = :erlang.phash2({tree, Mob.Theme.current()})

    if hash == s.last do
      s
    else
      send(s.owner, {__MODULE__, self(), {:view, tree}})
      %{s | last: hash}
    end
  end

  defp without_native_views(%{type: :native_view}),
    do: %{
      type: :text,
      props: %{text: "(this view can't be drawn in a tool's panel)", text_color: :muted},
      children: []
    }

  defp without_native_views(%{children: [_ | _] = kids} = node),
    do: %{node | children: kids |> List.flatten() |> Enum.map(&without_native_views/1)}

  defp without_native_views(node), do: node

  defp short(term), do: inspect(term, limit: 10, printable_limit: 200)
end
