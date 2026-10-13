# Drives the design gallery through every theme and cover on the given nodes
# and saves in-app screenshots, for checking the design plugin on simulators
# and emulators.
#
#   MOB_DEV_PATH=... mix run --no-start scripts/design_tour.exs OUT_DIR NODE [NODE ...]
#
# The app must already be running with distribution up (mix mob.deploy).

[out_dir | nodes] = System.argv()
File.mkdir_p!(out_dir)

# Hidden, so `global` doesn't link the device nodes to each other through us
# (two devices at once otherwise trip its overlapping-partition guard).
{:ok, _} = :net_kernel.start(:"design_tour_#{System.pid()}@127.0.0.1", %{name_domain: :longnames, hidden: true})
Node.set_cookie(MobDev.DistCookie.for_project!())

shot = fn node, name ->
  Process.sleep(900)
  {:ok, png} = Mob.Test.screenshot(node)
  prefix = node |> to_string() |> String.split("@") |> hd()
  path = Path.join(out_dir, "#{prefix}-#{name}.png")
  File.write!(path, png)
  IO.puts("  #{path}")
end

for node <- Enum.map(nodes, &String.to_atom/1) do
  Node.connect(node) || raise "can't reach #{node}"
  IO.puts(node)

  for cover <- [:leather, :paper], mode <- [:light, :dark, :night] do
    Mob.Test.tap(node, {:cover, cover})
    Mob.Test.tap(node, {:mode, mode})
    Mob.Test.scroll_to(node, "gallery", :top)
    shot.(node, "#{cover}-#{mode}-0")

    if cover == :leather do
      for page <- 1..4 do
        Mob.Test.scroll_to(node, "gallery", {:page, page})
        shot.(node, "#{cover}-#{mode}-#{page}")
      end
    end
  end

  Mob.Test.tap(node, {:mode, :dark})
  Mob.Test.tap(node, {:cover, :leather})
  Mob.Test.scroll_to(node, "gallery", :top)
  Mob.Test.tap(node, :open_sheet)
  shot.(node, "sheet")
  Mob.Test.tap(node, :close_sheet)
end
