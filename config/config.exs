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
  hints: [sign_in: "in Bezalel's Settings", switch_model: "in Bezalel's Settings"]

if config_env() == :test, do: import_config("test.exs")
