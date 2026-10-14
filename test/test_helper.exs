# Host tests run against throwaway state: the Repo on a temp database
# (config/test.exs), Mob.State on a temp dets file.
data_dir = Path.join(System.tmp_dir!(), "bezalel_test_#{System.unique_integer([:positive])}")
File.mkdir_p!(data_dir)
System.put_env("MOB_DATA_DIR", data_dir)

{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)
{:ok, _} = Bezalel.Repo.start_link()

Ecto.Migrator.run(Bezalel.Repo, Application.app_dir(:bezalel, "priv/repo/migrations"), :up,
  all: true,
  log: false
)

# The processes AppScreen talks to on device. Both run without the native
# layer: Mob.Device treats the missing NIF as a host run.
{:ok, _} = Mob.State.start_link()
{:ok, _} = Mob.Device.start_link()

ExUnit.start()
