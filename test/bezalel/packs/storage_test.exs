defmodule Bezalel.Packs.StorageTest do
  # Changes the packs directory and Storage's cached root, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Bezalel.Packs.Storage
  alias Bezalel.Study.{DB, Tools}

  @root_key {Storage, :root}

  setup do
    fixtures = Application.fetch_env!(:bezalel, :study_packs_dir)
    root = :persistent_term.get(@root_key, nil)
    tmp = Path.join(System.tmp_dir!(), "bezalel-storage-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    on_exit(fn ->
      Application.put_env(:bezalel, :study_packs_dir, fixtures)
      restore_root(root)
      File.rm_rf!(tmp)
    end)

    %{
      fixtures: fixtures,
      from: Path.join(tmp, "Documents/packs"),
      to: Path.join(tmp, "Support/packs")
    }
  end

  defp restore_root(nil), do: :persistent_term.erase(@root_key)
  defp restore_root(root), do: :persistent_term.put(@root_key, root)

  # Makes `dir` read-only (no new entries, none removed) for one test.
  defp read_only!(dir) do
    File.chmod!(dir, 0o500)
    on_exit(fn -> File.chmod!(dir, 0o755) end)
  end

  defp put!(dir, name, contents) do
    path = Path.join(dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  # Every file under `dir`, relative, with its contents.
  defp tree(dir) do
    for path <- Path.wildcard(Path.join(dir, "**"), match_dot: true),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, dir), File.read!(path)}
  end

  defp old_install(from) do
    put!(from, "core.sqlite", "core pack")
    put!(from, "notes.sqlite", "notes pack")
    put!(from, "installed.json", ~s({"packs": {}, "pending": ["lxx"]}))
    put!(from, "manifest.json", ~s({"schema": 1}))
    put!(from, ".download/abc.zst.part", "half a download")
  end

  describe "the packs directory" do
    test "without the config override it is packs under the app support root" do
      Application.delete_env(:bezalel, :study_packs_dir)
      :persistent_term.put(@root_key, "/phone/Library/Application Support")

      assert DB.dir() == "/phone/Library/Application Support/packs"
      assert DB.path(:core) == "/phone/Library/Application Support/packs/core.sqlite"
    end

    test "off the phone the root is Mob.data_dir/0, so a host run keeps its old packs" do
      Application.delete_env(:bezalel, :study_packs_dir)
      :persistent_term.erase(@root_key)

      assert Storage.root() == Mob.data_dir()
      assert DB.dir() == Storage.legacy_dir()
    end

    test "the config override wins" do
      Application.put_env(:bezalel, :study_packs_dir, "/somewhere/else")
      assert DB.dir() == "/somewhere/else"
    end
  end

  describe "migrate/3" do
    test "moves packs, installed.json, the manifest cache and partial downloads, then removes the old directory",
         %{from: from, to: to} do
      old_install(from)
      before = tree(from)

      assert Storage.migrate(from, to) == :ok
      assert tree(to) == before
      refute File.exists?(from)
    end

    test "nothing to move: no old directory, or the same one (Android)", %{from: from, to: to} do
      assert Storage.migrate(from, to) == :ok
      refute File.exists?(to)

      put!(to, "core.sqlite", "core pack")
      assert Storage.migrate(to, to) == :ok
      assert tree(to) == %{"core.sqlite" => "core pack"}
    end

    test "carries on from a partial move; a file already moved wins over its leftover",
         %{from: from, to: to} do
      old_install(from)
      # The first run moved core and the manifest, but died before deleting
      # an installed.json the new build had already rewritten.
      File.mkdir_p!(to)
      File.rename!(Path.join(from, "core.sqlite"), Path.join(to, "core.sqlite"))
      File.rename!(Path.join(from, "manifest.json"), Path.join(to, "manifest.json"))
      put!(to, "installed.json", ~s({"packs": {"core": {}}, "pending": []}))

      assert Storage.migrate(from, to) == :ok

      assert tree(to) == %{
               "core.sqlite" => "core pack",
               "notes.sqlite" => "notes pack",
               "manifest.json" => ~s({"schema": 1}),
               "installed.json" => ~s({"packs": {"core": {}}, "pending": []}),
               ".download/abc.zst.part" => "half a download"
             }

      refute File.exists?(from)
    end

    test "across volumes it copies, and redoes a copy an interruption left half done",
         %{from: from, to: to} do
      old_install(from)
      before = tree(from)
      put!(to, "core.sqlite.migrating", "core p")
      cross_volume = fn _src, _dst -> {:error, :exdev} end

      assert Storage.migrate(from, to, cross_volume) == :ok
      assert tree(to) == before
      refute File.exists?(from)
    end

    test "a file that can't be moved stays, with the directory, for the next start",
         %{from: from, to: to} do
      old_install(from)
      before = tree(from)
      core = Path.join(from, "core.sqlite")

      stuck = fn
        ^core, _dst -> {:error, :eacces}
        src, dst -> File.rename(src, dst)
      end

      assert Storage.migrate(from, to, stuck) == {:error, [{core, :eacces}]}
      assert tree(from) == %{"core.sqlite" => "core pack"}

      assert Storage.migrate(from, to) == :ok
      assert tree(to) == before
      refute File.exists?(from)
    end

    test "a destination of another type is a failure, and nothing is deleted",
         %{from: from, to: to} do
      put!(from, "core.sqlite", "core pack")
      put!(from, ".download/abc.part", "part")
      File.mkdir_p!(Path.join(to, "core.sqlite"))
      put!(to, ".download", "a file where the directory goes")

      assert {:error, failures} = Storage.migrate(from, to)

      assert Enum.sort(failures) ==
               Enum.sort([
                 {Path.join(from, "core.sqlite"), :eexist},
                 {Path.join(from, ".download"), :eexist}
               ])

      assert tree(from) == %{"core.sqlite" => "core pack", ".download/abc.part" => "part"}
    end

    test "a symlink moves as a link; what it points at stays put", %{from: from, to: to} do
      outside = Path.join(Path.dirname(Path.dirname(from)), "outside")
      put!(outside, "core.sqlite", "core pack")
      put!(outside, "parts/abc.part", "part")
      File.mkdir_p!(from)
      File.ln_s!(Path.join(outside, "core.sqlite"), Path.join(from, "core.sqlite"))
      File.ln_s!(Path.join(outside, "parts"), Path.join(from, ".download"))

      assert Storage.migrate(from, to) == :ok

      assert File.read_link(Path.join(to, "core.sqlite")) ==
               {:ok, Path.join(outside, "core.sqlite")}

      assert File.read_link(Path.join(to, ".download")) == {:ok, Path.join(outside, "parts")}
      assert tree(outside) == %{"core.sqlite" => "core pack", "parts/abc.part" => "part"}
      refute File.exists?(from)
    end

    test "a directory that can't be created is a failure; its contents stay",
         %{from: from, to: to} do
      put!(from, ".download/abc.part", "part")
      File.mkdir_p!(to)
      read_only!(to)

      assert Storage.migrate(from, to) == {:error, [{Path.join(to, ".download"), :eacces}]}
      assert tree(from) == %{".download/abc.part" => "part"}
    end

    test "an old directory that can't be removed is reported, with everything moved",
         %{from: from, to: to} do
      old_install(from)
      before = tree(from)
      read_only!(Path.dirname(from))

      assert Storage.migrate(from, to) == {:error, [{from, :eacces}]}
      assert tree(to) == before
      assert File.ls!(from) == []
    end

    test "the study tools read a moved pack", %{fixtures: fixtures, from: from, to: to} do
      File.mkdir_p!(from)
      File.cp!(Path.join(fixtures, "core.sqlite"), Path.join(from, "core.sqlite"))

      :ok = Storage.migrate(from, to)
      Application.put_env(:bezalel, :study_packs_dir, to)

      assert {:ok, {:details, text, _}} =
               Tools.LookupVerse.run(%{"reference" => "Exodus 31:3"}, %{})

      assert text =~ "Exo.31.3"
    end
  end

  describe "prepare/1" do
    test "creates the directory and excludes it before moving the old packs in, at every start",
         %{from: from, to: to} do
      old_install(from)
      before = tree(from)
      test = self()
      # What the directory holds when it's excluded: nothing yet, the first
      # time, so no pack sits in it unexcluded if the app dies mid-move.
      exclude = fn dir -> send(test, {:excluded, dir, File.ls(dir)}) && :ok end

      assert Storage.prepare(from: from, to: to, exclude: exclude) == :ok
      assert_received {:excluded, ^to, {:ok, []}}
      assert tree(to) == before

      assert Storage.prepare(from: from, to: to, exclude: exclude) == :ok
      assert_received {:excluded, ^to, {:ok, [_ | _]}}
    end

    test "a fresh install gets an empty, excluded directory", %{from: from, to: to} do
      test = self()
      exclude = fn dir -> send(test, {:excluded, dir}) && :ok end

      assert Storage.prepare(from: from, to: to, exclude: exclude) == :ok
      assert_received {:excluded, ^to}
      assert File.ls!(to) == []
    end

    test "a failed move or exclusion is logged, and the app starts anyway", %{from: from, to: to} do
      old_install(from)
      core = Path.join(from, "core.sqlite")

      stuck = fn
        ^core, _ -> {:error, :eacces}
        src, dst -> File.rename(src, dst)
      end

      log =
        capture_log(fn ->
          assert Storage.prepare(
                   from: from,
                   to: to,
                   rename: stuck,
                   exclude: fn _ -> {:error, "no such volume"} end
                 ) == :ok
        end)

      assert log =~ "can't move #{core}"
      assert log =~ "can't exclude #{to} from backup"
    end

    test "with the config override set, the old directory isn't moved into it",
         %{from: from, to: to} do
      # legacy_dir/0 is packs under Mob.data_dir/0, i.e. under MOB_DATA_DIR.
      previous = System.get_env("MOB_DATA_DIR")
      System.put_env("MOB_DATA_DIR", Path.dirname(from))

      on_exit(fn ->
        if previous,
          do: System.put_env("MOB_DATA_DIR", previous),
          else: System.delete_env("MOB_DATA_DIR")
      end)

      assert Storage.legacy_dir() == from
      old_install(from)
      Application.put_env(:bezalel, :study_packs_dir, to)

      assert Storage.prepare(exclude: fn _ -> :ok end) == :ok
      assert File.ls!(to) == []
      assert File.exists?(Path.join(from, "core.sqlite"))
    end
  end
end
