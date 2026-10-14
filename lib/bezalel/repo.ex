defmodule Bezalel.Repo do
  use Ecto.Repo,
    otp_app: :bezalel,
    adapter: Ecto.Adapters.SQLite3

  @impl true
  def init(_type, config) do
    # MOB_DATA_DIR is set by mob_beam.c (Android) and mob_beam.m (iOS) to the
    # platform's appropriate persistent storage directory:
    #   Android — context.getFilesDir()  (app-private, survives updates)
    #   iOS     — NSDocumentDirectory    (app-private, iCloud-backed)
    #
    # When not running on device (e.g. mix ecto.migrate in dev), falls back to
    # priv/repo/ in the project root so local development works without any
    # setup. A configured :database (config/test.exs) wins over both.
    database =
      config[:database] ||
        Path.join(
          System.get_env("MOB_DATA_DIR") || System.get_env("HOME") ||
            Path.join(File.cwd!(), "priv/repo"),
          "app.db"
        )

    File.mkdir_p!(Path.dirname(database))
    {:ok, Keyword.merge(config, database: database, pool_size: 1)}
  end
end
