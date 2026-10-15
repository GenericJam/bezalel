import Config

# Host tests: a throwaway database per run instead of the device's data dir.
config :bezalel, Bezalel.Repo,
  database: Path.join(System.tmp_dir!(), "bezalel_test_#{System.unique_integer([:positive])}.db")

# The study tools read the small packs cut by data/scripts/make_fixtures.py,
# never the real ones in data/out.
config :bezalel, :study_packs_dir, Path.expand("../test/fixtures/packs", __DIR__)

config :logger, level: :warning

# Sign-ins and API keys in memory, and the sign-in page "opened" into the
# test process's mailbox (Bezalel.Test.Fakes), so nothing reaches a
# keychain or a browser.
config :rho,
  credential_store: Bezalel.Test.MemoryStore,
  open_url: {Bezalel.Test.Browser, :open, []}
