defmodule Bezalel.Workshop.Screens do
  @moduledoc """
  Dyn screens in Bezalel (`config :rho, :dyn, screens: ...`): mob's
  (`Rho.Dyn.Screens.Mob`), drawn inside a built tool's panel by
  `Bezalel.Workshop.Host`. Only the agent's screen rules differ: the panel
  scrolls and frames the screen, and of Mob only the modules
  `config :rho, :dyn, check: [gated: ...]` lets through are there.
  """
  @behaviour Rho.Dyn.Screens

  alias Rho.Dyn.Screens.Mob, as: MobScreens

  @impl true
  defdelegate screen_source?(forms), to: MobScreens

  @impl true
  defdelegate entry(), to: MobScreens

  @impl true
  defdelegate screen?(module), to: MobScreens

  @impl true
  defdelegate selftest(module), to: MobScreens

  @impl true
  defdelegate after_first_render(mfa), to: MobScreens

  @impl true
  defdelegate subscribe_app_events(), to: MobScreens

  @impl true
  defdelegate left_app?(message), to: MobScreens

  @impl true
  def guide do
    """
    - A screen: `use Mob.Screen` with `mount/3`, `render/1` (a `~MOB` template) and \
    `handle_info/2` for its events; it must mount on an empty socket (`params` is `%{}`) and \
    render. It is drawn inside the tool's panel, under the tool's name and above its buttons: \
    `render/1` returns a `<Column>` (no `<Scroll>`, no top or tab bar: the panel scrolls and \
    has them). Events come to `handle_info/2` as `{:tap, tag}` for `on_tap={{self(), tag}}` \
    and `{:change, tag, value}` for `on_change={{self(), tag}}`; do the work there (study \
    library reads are quick) and keep the result in assigns. No `start_async`, no navigation \
    (`push_screen` and the like do nothing). `selftest/0` is optional for screens.
    - Of Mob: `Mob.Screen`, `Mob.Socket`, `~MOB` (`Mob.Sigil`), `Mob.UI`, `Mob.Style`, \
    `Mob.List`, `Mob.Font`, `Mob.Motion`, `Mob.Haptic`, `Mob.Clipboard`, `Mob.Alert`, \
    `Mob.Share`, `Mob.Canvas`, `Mob.Speech`. Not the theme, `Mob.State`, the device, files or \
    web views.\
    """
  end
end
