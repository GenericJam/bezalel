defmodule Bezalel.PacksTest do
  use ExUnit.Case, async: true

  alias Bezalel.Packs
  alias Bezalel.Packs.Download
  alias Bezalel.Study.DB
  alias Bezalel.Test.PackServer

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    {server, base} = PackServer.start()
    core = PackServer.pack("core", "v1")
    notes = PackServer.pack("notes", "v1")
    url = PackServer.publish(server, base, 1, [{"core", core, true}, {"notes", notes, false}])
    %{server: server, base: base, url: url, dir: dir, core: core, notes: notes}
  end

  defp start(ctx, opts \\ []) do
    opts =
      Keyword.merge(
        [name: nil, dir: ctx.dir, manifest_url: ctx.url, retry_delays: [0, 0, 0]],
        opts
      )

    pid = start_supervised!({Packs, opts}, id: make_ref())
    :ok = Packs.subscribe(pid)
    pid
  end

  defp loaded(pid), do: wait(pid, &(&1.data_version != nil and not &1.checking))

  defp wait(pid, done?, tries \\ 250) do
    status = Packs.status(pid)

    cond do
      done?.(status) -> status
      tries == 0 -> flunk("the library never got there: #{inspect(status)}")
      true -> wait(pid, done?, Process.sleep(20) && tries - 1)
    end
  end

  defp download(pid, name) do
    :ok = Packs.download(name, pid)
    assert_receive {:bezalel_packs, {:notice, notice}}, 5_000
    notice
  end

  defp check(pid) do
    :ok = Packs.check(pid)
    assert_receive {:bezalel_packs, {:notice, notice}}, 5_000
    notice
  end

  defp pack(status, name), do: Enum.find(status.packs, &(&1.name == name))
  defp pack_file(ctx, name), do: Path.join(ctx.dir, name <> ".sqlite")

  defp record(ctx, name) do
    ctx.dir
    |> Path.join("installed.json")
    |> File.read!()
    |> JSON.decode!()
    |> get_in(["packs", name])
  end

  defp staging(ctx), do: ctx.dir |> Download.staging_dir() |> Path.join("*") |> Path.wildcard()

  # The Range header of each download of `name`'s file (nil: from the start).
  defp gets(server, name) do
    for {path, range} <- PackServer.requests(server),
        String.ends_with?(path, "/#{name}.sqlite.zst"),
        do: range
  end

  defp manifest(ctx), do: Req.get!(ctx.url, decode_body: false).body |> JSON.decode!()

  defp republish_manifest(ctx, manifest),
    do: PackServer.put_file(ctx.server, "/packs/manifest.json", JSON.encode!(manifest))

  defp entry(ctx, name) do
    {:ok, manifest} = ctx |> manifest() |> JSON.encode!() |> Packs.Manifest.parse()
    Packs.Manifest.entry(manifest, name)
  end

  test "first launch: the packs are listed with their sizes; core downloads and the tools open it",
       ctx do
    pid = start(ctx)
    status = loaded(pid)

    assert status.data_version == 1
    assert %{required: true, installed: nil, state: :idle} = core = pack(status, "core")
    assert {core.size, core.raw_size} == {byte_size(ctx.core.zst), byte_size(ctx.core.raw)}
    assert %{required: false, installed: nil} = pack(status, "notes")
    assert status.storage == 0

    assert download(pid, "core") == "The core pack is ready."
    assert File.read!(pack_file(ctx, "core")) == ctx.core.raw
    assert record(ctx, "core")["data_version"] == 1
    assert staging(ctx) == []

    status = Packs.status(pid)
    assert %{installed: %{data_version: 1}, state: :idle, update: false} = pack(status, "core")
    assert status.storage == byte_size(ctx.core.raw)

    previous = Application.fetch_env!(:bezalel, :study_packs_dir)
    Application.put_env(:bezalel, :study_packs_dir, ctx.dir)

    try do
      assert {:ok, [%{"pack" => "core"}]} =
               DB.with_pack(:core, &DB.all(&1, "SELECT pack FROM pack_meta"))
    after
      Application.put_env(:bezalel, :study_packs_dir, previous)
    end
  end

  test "a download that doesn't match its checksum is refused, fetched once more, and leaves nothing",
       ctx do
    # Same length, other bytes: only the checksum can tell.
    PackServer.put_file(
      ctx.server,
      "/packs/v1/core.sqlite.zst",
      :binary.copy(<<0>>, byte_size(ctx.core.zst))
    )

    pid = start(ctx)
    loaded(pid)

    assert download(pid, "core") ==
             "Couldn't download the core pack: the download didn't match its checksum."

    assert gets(ctx.server, "core") == [nil, nil]
    refute File.exists?(pack_file(ctx, "core"))
    assert staging(ctx) == []
    assert %{installed: nil, error: "Couldn't download" <> _} = pack(Packs.status(pid), "core")
  end

  test "a pack that unpacks to the wrong file is refused", ctx do
    republish_manifest(
      ctx,
      put_in(manifest(ctx), ["packs", Access.at(0), "raw_sha256"], String.duplicate("0", 64))
    )

    pid = start(ctx)
    loaded(pid)

    assert download(pid, "core") ==
             "Couldn't download the core pack: the unpacked pack didn't match its checksum."

    refute File.exists?(pack_file(ctx, "core"))
    assert staging(ctx) == []
  end

  test "a connection dropped mid-download resumes where it stopped", ctx do
    PackServer.cut(ctx.server, "/packs/v1/core.sqlite.zst", 1000)
    pid = start(ctx)
    loaded(pid)

    assert download(pid, "core") == "The core pack is ready."
    assert gets(ctx.server, "core") == [nil, "bytes=1000-"]
    assert File.read!(pack_file(ctx, "core")) == ctx.core.raw
  end

  # What a kill mid-download leaves: the manifest and the queue on disk,
  # the first `bytes` of the download, a half-written unpacked file.
  defp killed(ctx, bytes) do
    entry = entry(ctx, "core")
    File.write!(Path.join(ctx.dir, "manifest.json"), JSON.encode!(manifest(ctx)))
    File.write!(Path.join(ctx.dir, "installed.json"), ~s({"packs": {}, "pending": ["core"]}))
    File.mkdir_p!(Download.staging_dir(ctx.dir))
    File.write!(Download.part(ctx.dir, entry), binary_part(ctx.core.zst, 0, bytes))
    File.write!(Download.raw_part(ctx.dir, entry), "half a pack")
    length(PackServer.requests(ctx.server))
  end

  defp installed(pid), do: wait(pid, &match?(%{installed: %{}}, pack(&1, "core")))

  test "a download the app was killed in resumes on the next start; the unverified file never shows",
       ctx do
    seen = killed(ctx, 1500)
    pid = start(ctx)

    assert pack(installed(pid), "core").installed.data_version == 1
    # From the part, with the manifest it had: nothing asked for it again.
    assert ctx.server |> PackServer.requests() |> Enum.drop(seen) ==
             [{"/packs/v1/core.sqlite.zst", "bytes=1500-"}]

    assert File.read!(pack_file(ctx, "core")) == ctx.core.raw
    assert staging(ctx) == []
  end

  test "a server that ignores the range sends the whole file, which replaces the part", ctx do
    killed(ctx, 1500)
    PackServer.ignore_range(ctx.server)
    pid = start(ctx)
    installed(pid)

    assert gets(ctx.server, "core") == ["bytes=1500-"]
    assert File.read!(pack_file(ctx, "core")) == ctx.core.raw
  end

  describe "updates" do
    setup ctx do
      pid = start(ctx)
      loaded(pid)
      assert download(pid, "core") == "The core pack is ready."
      assert download(pid, "notes") == "The notes pack is ready."
      %{pid: pid}
    end

    test "nothing newer: up to date, nothing fetched", ctx do
      assert check(ctx.pid) == "Up to date: study library version 1."
      assert gets(ctx.server, "core") == [nil]
    end

    test "a newer library replaces only the changed pack, and only once the new one has verified",
         ctx do
      core2 = PackServer.pack("core", "v2")

      PackServer.publish(ctx.server, ctx.base, 2, [
        {"core", core2, true},
        {"notes", ctx.notes, false}
      ])

      # The first attempt at v2 is corrupt.
      PackServer.put_file(
        ctx.server,
        "/packs/v2/core.sqlite.zst",
        :binary.copy(<<1>>, byte_size(core2.zst))
      )

      :ok = Packs.check(ctx.pid)

      assert_receive {:bezalel_packs, {:notice, "Updating core to study library version 2."}},
                     5_000

      assert_receive {:bezalel_packs, {:notice, "Couldn't download the core pack: " <> _}}, 5_000

      # The old pack is still the one in use, recorded as v1, with the
      # update still offered.
      assert File.read!(pack_file(ctx, "core")) == ctx.core.raw
      assert record(ctx, "core")["data_version"] == 1
      assert %{update: true, installed: %{data_version: 1}} = pack(Packs.status(ctx.pid), "core")

      PackServer.put_file(ctx.server, "/packs/v2/core.sqlite.zst", core2.zst)
      assert check(ctx.pid) == "Updating core to study library version 2."
      assert_receive {:bezalel_packs, {:notice, "The core pack is ready."}}, 5_000

      assert File.read!(pack_file(ctx, "core")) == core2.raw
      assert record(ctx, "core")["data_version"] == 2
      # notes didn't change: recorded as v2 without a download.
      assert record(ctx, "notes")["data_version"] == 2
      assert gets(ctx.server, "notes") == [nil]
      assert check(ctx.pid) == "Up to date: study library version 2."
    end

    test "an optional pack can be removed; core can't", ctx do
      assert :ok = Packs.remove("notes", ctx.pid)
      refute File.exists?(pack_file(ctx, "notes"))
      assert record(ctx, "notes") == nil
      assert %{installed: nil} = pack(Packs.status(ctx.pid), "notes")

      assert {:error, "The core pack is needed" <> _} = Packs.remove("core", ctx.pid)
      assert File.exists?(pack_file(ctx, "core"))
    end
  end

  test "a pack copied on by hand is kept when it matches the library, and replaced when it doesn't",
       ctx do
    File.write!(pack_file(ctx, "core"), ctx.core.raw)
    File.write!(pack_file(ctx, "notes"), "an old notes pack")
    pid = start(ctx)
    loaded(pid)
    assert %{installed: %{data_version: nil}} = pack(Packs.status(pid), "core")

    assert check(pid) == "Checking core, notes against study library version 1."
    assert_receive {:bezalel_packs, {:notice, "The core pack is ready."}}, 5_000
    assert_receive {:bezalel_packs, {:notice, "The notes pack is ready."}}, 5_000

    assert gets(ctx.server, "core") == []
    assert gets(ctx.server, "notes") == [nil]
    assert File.read!(pack_file(ctx, "notes")) == ctx.notes.raw
    assert record(ctx, "core")["data_version"] == 1
  end

  test "an unreachable library is reported, and a download waiting for it gives up", ctx do
    pid = start(ctx, manifest_url: "http://127.0.0.1:9/packs/manifest.json")
    :ok = Packs.download("core", pid)
    assert_receive {:bezalel_packs, {:notice, "Couldn't reach the study library" <> _}}, 5_000
    assert %{state: :idle, error: "Couldn't reach" <> _} = pack(Packs.status(pid), "core")
  end
end
