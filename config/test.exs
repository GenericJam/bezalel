import Config

# Host tests: a throwaway database per run instead of the device's data dir.
config :bezalel, Bezalel.Repo,
  database: Path.join(System.tmp_dir!(), "bezalel_test_#{System.unique_integer([:positive])}.db")

config :logger, level: :warning
