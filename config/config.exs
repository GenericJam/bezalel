import Config

# Register the Repo so Mix tasks (mix ecto.create, mix ecto.migrate) can
# discover it. The actual database path is configured at runtime in
# Bezalel.Repo.init/2 via the MOB_DATA_DIR environment variable.
config :bezalel, ecto_repos: [Bezalel.Repo]

# Wire the Repo into Mob.ScreenState so screens using `vsn:` get automatic
# state persistence. Remove this line to disable screen state persistence.
config :mob, :repo, Bezalel.Repo

# rho, the agent core (models, sign-in, usage). It keeps its files in the
# app's data dir and the sign-ins and API keys in the platform's secure store.
config :rho,
  data_dir: {Mob, :data_dir, []},
  credential_store: MobSecureStore,
  app_name: "Bezalel",
  namespace: "bezalel",
  open_url: {Mob.Device, :open_url, []},
  hints: [
    sign_in: "in Bezalel's Settings",
    switch_model: "in Bezalel's Settings",
    approve: "in the Workshop, where they see what it adds and tap Approve"
  ]

# The Dyn layer: the study tools the Workshop builds (Bezalel.Workshop,
# decisions/2026-10-15-workshop-on-dyn.md). The namespace names the
# generations on disk, so it stays. Built code may read the study library
# through Bezalel.Workshop.Study and draw with Mob's and MobBezalel's UI;
# nothing else of Bezalel (the Library, the packs, the settings), no
# network, no storage.
config :rho, :dyn,
  enabled: true,
  namespace: Bezalel.Dyn,
  app: :bezalel,
  core: [Bezalel],
  allowed: [Bezalel.Workshop.Study],
  check: [
    # Of Mob, what a study tool's screen draws with: not the theme (it's the
    # app's), the stored settings (Mob.State holds Bezalel's), the device,
    # files, notifications, wake-ups or a web view.
    gated: %{
      "Mob" => ~w(Mob.Screen Mob.Socket Mob.Sigil Mob.UI Mob.Style Mob.SizeClass Mob.List Mob.Font
           Mob.Motion Mob.Haptic Mob.Clipboard Mob.Alert Mob.Share Mob.Event Mob.Canvas
           Mob.Speech)
    },
    banned: %{
      Req => "reaches the network (built tools work offline)",
      ReqLLM => "calls models with the user's sign-in",
      Finch => "reaches the network",
      Mint => "reaches the network",
      Exqlite =>
        "opens databases directly (read the study library through Bezalel.Workshop.Study)",
      Ecto => "reaches Bezalel's database"
    },
    banned_erlang: %{
      httpc: "reaches the network",
      gen_tcp: "reaches the network",
      gen_udp: "reaches the network",
      gen_sctp: "reaches the network",
      ssl: "reaches the network",
      inet: "reaches the network",
      socket: "reaches the network",
      dets: "opens files on disk",
      disk_log: "opens files on disk",
      # Mob's native layer: under the gated Mob modules, with the device's
      # own calls (open a URL, drive the UI, quit the app).
      mob_nif: "is Mob's native layer (draw with Mob's UI modules)"
    }
  ],
  screens: Bezalel.Workshop.Screens,
  guide: {Bezalel.Workshop.Prompt, :dyn_guide, []}

if config_env() == :test, do: import_config("test.exs")
