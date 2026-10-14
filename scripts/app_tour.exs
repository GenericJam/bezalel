# Walks the app through its screens and main interactions on the given nodes
# and saves in-app screenshots (sheets on Android are separate windows the
# in-app capture can't see; check those with adb screencap).
#
#   mix run --no-start scripts/app_tour.exs OUT_DIR NODE [NODE ...]
#
# The app must already be running with distribution up (mix mob.deploy).
# It sends the same {:tap, tag} / {:change, tag, value} messages a tap does.

[out_dir | nodes] = System.argv()
File.mkdir_p!(out_dir)

{:ok, _} =
  :net_kernel.start(:"app_tour_#{System.pid()}@127.0.0.1", %{name_domain: :longnames, hidden: true})

Node.set_cookie(MobDev.DistCookie.for_project!())

for node <- Enum.map(nodes, &String.to_atom/1) do
  Node.connect(node) || raise "can't reach #{node}"
  IO.puts(node)
  prefix = node |> to_string() |> String.split("@") |> hd()
  screen = {:mob_screen, node}

  tap = fn tag -> send(screen, {:tap, tag}) end
  change = fn tag, value -> send(screen, {:change, tag, value}) end

  shot = fn name, wait ->
    Process.sleep(wait)
    {:ok, png} = Mob.Test.screenshot(node)
    path = Path.join(out_dir, "#{prefix}-#{name}.png")
    File.write!(path, png)
    IO.puts("  #{path}")
  end

  steps = [
    {"01-study", fn -> tap.({:tab, :study}) end},
    {"02-expand-all", fn -> tap.({:study, :toggle_all}) end},
    {"03-collapse-all", fn -> tap.({:study, :toggle_all}) end},
    {"04-ask", fn ->
       change.(:draft, "Tell me about “filled”")
       tap.({:study, :send})
     end},
    {"05-conversations", fn -> tap.({:tab, :convs}) end},
    {"06-workshop", fn -> tap.({:tab, :workshop}) end},
    {"07-building", fn ->
       change.(:desc, "Sermon outline helper: Exodus 31")
       tap.({:workshop, :build})
     end},
    {"08-tool", fn -> Process.sleep(1500) end},
    {"09-tool-move", fn -> tap.({:tool, {:move, 1}}) end},
    {"10-settings", fn -> tap.({:tab, :settings}) end},
    {"11-settings-paper-light", fn ->
       tap.({:settings, {:cover, :paper}})
       tap.({:settings, {:mode, :light}})
     end},
    {"12-study-paper-light", fn -> tap.({:tab, :study}) end},
    {"13-night", fn ->
       tap.({:settings, {:mode, :night}})
       tap.({:settings, {:cover, :leather}})
     end},
    {"14-dark-restore", fn -> tap.({:settings, {:mode, :dark}}) end}
  ]

  for {name, action} <- steps do
    action.()
    shot.(name, 1200)
  end
end
