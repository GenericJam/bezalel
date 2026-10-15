defmodule Bezalel.Packs.Download do
  @moduledoc """
  Fetches one pack and installs it, in the calling process (a task of
  `Bezalel.Packs`):

    1. the `.sqlite.zst` into `<dir>/.download/<sha256>.zst.part`. The name
       is the download's checksum, so a download cut off (connection lost,
       app killed) resumes with a `Range` request, and a part of some other
       version is never continued into this one;
    2. checks its size and sha256 (a mismatch deletes the part);
    3. decompresses it with OTP's `:zstd` into
       `<dir>/.download/<raw_sha256>.sqlite.part`, hashing as it writes, and
       checks the raw size and sha256;
    4. syncs it and renames it over `<dir>/<name>.sqlite`.

  `Bezalel.Study.DB` opens only `<dir>/<name>.sqlite`, and a rename within
  a directory is atomic, so the tools see the old pack (or none) until the
  new one has verified, then the new one; never a partial file. A reader
  with the old file open keeps reading it.
  """

  alias Bezalel.Packs.Manifest

  @chunk 1_048_576

  @typedoc "`{phase, done, total}` in bytes: downloaded, or decompressed and checked."
  @type progress :: {:downloading | :installing, non_neg_integer(), pos_integer()}

  @type error ::
          {:transport, String.t()}
          | {:http, pos_integer()}
          | :range
          | :checksum
          | :raw_checksum
          | {:file, File.posix() | term()}

  @doc """
  Installs `entry` into `dir`. `on_progress` is called with `t:progress/0`
  as bytes arrive and as the pack is checked. Options: `:req_options`
  (merged into the download request; tests point it at a local server),
  `:adopt` (first check whether the file already in place is this pack,
  as when a pack was copied onto the device by hand, and keep it if so).
  """
  @spec run(Manifest.entry(), Path.t(), (progress() -> any()), keyword()) ::
          :ok | {:error, error()}
  def run(entry, dir, on_progress, opts \\ []) do
    staging = staging_dir(dir)
    target = Path.join(dir, entry.name <> ".sqlite")

    with :ok <- mkdir(staging) do
      if opts[:adopt] && same?(target, entry, on_progress),
        do: :ok,
        else: fetch_and_install(entry, staging, target, on_progress, opts)
    end
  end

  @doc "Where partial downloads and unverified packs are kept."
  @spec staging_dir(Path.t()) :: Path.t()
  def staging_dir(dir), do: Path.join(dir, ".download")

  @doc "The partial download of `entry`."
  @spec part(Path.t(), Manifest.entry()) :: Path.t()
  def part(dir, entry), do: Path.join(staging_dir(dir), entry.sha256 <> ".zst.part")

  @doc "The unverified decompressed pack of `entry`."
  @spec raw_part(Path.t(), Manifest.entry()) :: Path.t()
  def raw_part(dir, entry), do: Path.join(staging_dir(dir), entry.raw_sha256 <> ".sqlite.part")

  defp fetch_and_install(entry, staging, target, on_progress, opts) do
    part = Path.join(staging, entry.sha256 <> ".zst.part")
    raw = Path.join(staging, entry.raw_sha256 <> ".sqlite.part")

    with :ok <- download(entry, part, on_progress, opts),
         :ok <- verify_download(entry, part),
         :ok <- decompress(entry, part, raw, on_progress),
         :ok <- rename(raw, target) do
      File.rm(part)
      :ok
    end
  end

  # ── Download ──────────────────────────────────────────────────────────────

  defp download(entry, part, on_progress, opts) do
    case File.stat(part) do
      {:ok, %{size: size}} when size == entry.size ->
        :ok

      {:ok, %{size: size}} when size < entry.size ->
        request(entry, part, size, on_progress, opts)

      _ ->
        File.rm(part)
        request(entry, part, 0, on_progress, opts)
    end
  end

  defp request(entry, part, offset, on_progress, opts) do
    with {:ok, io} <- open(part, [:read, :write]) do
      try do
        do_request(entry, io, offset, on_progress, opts)
      after
        :file.close(io)
      end
    end
  end

  defp do_request(entry, io, offset, on_progress, opts) do
    on_progress.({:downloading, offset, entry.size})
    range = if offset > 0, do: [{"range", "bytes=#{offset}-"}], else: []

    into = fn {:data, data}, {req, resp} ->
      case write_chunk(resp, data, io, offset, entry, on_progress) do
        %{private: %{pack_error: _}} = resp -> {:halt, {req, resp}}
        resp -> {:cont, {req, resp}}
      end
    end

    request =
      Req.new(
        url: entry.url,
        headers: range,
        into: into,
        retry: false,
        raw: true,
        receive_timeout: 60_000
      )
      |> Req.merge(Keyword.get(opts, :req_options, []))

    case Req.request(request) do
      {:ok, %{private: %{pack_error: error}}} ->
        error

      {:ok, %{status: status}} when status in [200, 206] ->
        :ok

      {:ok, %{status: 416}} ->
        # The part is longer than the file (or the server lost it): start over.
        :file.position(io, 0)
        :file.truncate(io)
        {:error, :range}

      {:ok, %{status: status}} ->
        {:error, {:http, status}}

      {:error, exception} ->
        {:error, {:transport, Exception.message(exception)}}
    end
  end

  # The first chunk of a response decides where the bytes go: a 206 from
  # the offset continues the part; a 200 (the server ignored the range)
  # starts it again. Anything else (a redirect's or an error's body) isn't
  # written. Errors are kept on the response and returned after the request.
  defp write_chunk(%{private: %{pack_error: _}} = resp, _data, _io, _offset, _entry, _progress),
    do: resp

  defp write_chunk(%{status: status} = resp, data, io, offset, entry, on_progress)
       when status in [200, 206] do
    received =
      case Req.Response.get_private(resp, :pack_received) do
        nil -> start(resp, io, offset)
        n -> n
      end

    with received when is_integer(received) <- received,
         :ok <- :file.write(io, data) do
      received = received + byte_size(data)
      on_progress.({:downloading, received, entry.size})
      Req.Response.put_private(resp, :pack_received, received)
    else
      {:error, reason} -> Req.Response.put_private(resp, :pack_error, {:error, error(reason)})
    end
  end

  defp write_chunk(resp, _data, _io, _offset, _entry, _progress), do: resp

  defp start(%{status: 206} = resp, io, offset) do
    if content_range_start(resp) == offset do
      with {:ok, _} <- :file.position(io, offset), do: offset
    else
      :file.position(io, 0)
      :file.truncate(io)
      {:error, :range}
    end
  end

  defp start(%{status: 200}, io, _offset) do
    with {:ok, _} <- :file.position(io, 0),
         :ok <- :file.truncate(io),
         do: 0
  end

  defp content_range_start(resp) do
    with [value | _] <- Req.Response.get_header(resp, "content-range"),
         "bytes " <> rest <- value,
         {start, "-" <> _} <- Integer.parse(rest) do
      start
    else
      _ -> nil
    end
  end

  defp error(:range), do: :range
  defp error(reason), do: {:file, reason}

  defp verify_download(entry, part) do
    if hash_file(part) == {entry.size, entry.sha256} do
      :ok
    else
      File.rm(part)
      {:error, :checksum}
    end
  end

  # ── Decompress and check ──────────────────────────────────────────────────

  defp decompress(entry, part, raw, on_progress) do
    on_progress.({:installing, 0, entry.raw_size})
    {:ok, ctx} = :zstd.context(:decompress)

    with {:ok, input} <- open(part, [:read]),
         {:ok, output} <- open(raw, [:write]) do
      result =
        try do
          stream(ctx, input, output, {0, :crypto.hash_init(:sha256)}, entry, on_progress)
        after
          :file.close(input)
          :zstd.close(ctx)
        end

      finish(result, output, entry, raw)
    end
  end

  defp stream(ctx, input, output, acc, entry, on_progress) do
    case :file.read(input, @chunk) do
      {:ok, data} ->
        with {:ok, acc} <- inflate(ctx, data, output, acc, entry, on_progress),
             do: stream(ctx, input, output, acc, entry, on_progress)

      :eof ->
        {:done, out} = :zstd.finish(ctx, <<>>)
        put(output, out, acc)

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  defp inflate(ctx, data, output, acc, entry, on_progress) do
    {rest, out} =
      case :zstd.stream(ctx, data) do
        {:continue, rest, out} -> {rest, out}
        {:continue, out} -> {[], out}
      end

    with {:ok, {size, _} = acc} <- put(output, out, acc) do
      on_progress.({:installing, min(size, entry.raw_size), entry.raw_size})

      if IO.iodata_length(rest) == 0,
        do: {:ok, acc},
        else: inflate(ctx, rest, output, acc, entry, on_progress)
    end
  end

  defp put(output, data, {size, hash}) do
    case :file.write(output, data) do
      :ok -> {:ok, {size + IO.iodata_length(data), :crypto.hash_update(hash, data)}}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp finish(result, output, entry, raw) do
    synced = with {:ok, _} <- result, do: :file.sync(output)
    :file.close(output)

    case {result, synced} do
      {{:ok, {size, hash}}, :ok} ->
        if {size, hex(hash)} == {entry.raw_size, entry.raw_sha256} do
          :ok
        else
          File.rm(raw)
          {:error, :raw_checksum}
        end

      {{:error, _} = error, _} ->
        File.rm(raw)
        error

      {_, {:error, reason}} ->
        File.rm(raw)
        {:error, {:file, reason}}
    end
  end

  defp rename(raw, target) do
    case :file.rename(raw, target) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  # ── Adopting a pack already in place ─────────────────────────────────────

  defp same?(target, entry, on_progress) do
    case File.stat(target) do
      {:ok, %{size: size}} when size == entry.raw_size ->
        on_progress.({:installing, 0, entry.raw_size})
        hash_file(target) == {entry.raw_size, entry.raw_sha256}

      _ ->
        false
    end
  end

  @doc "`{size, sha256 hex}` of a file, or nil if it can't be read."
  @spec hash_file(Path.t()) :: {non_neg_integer(), String.t()} | nil
  def hash_file(path) do
    case open(path, [:read]) do
      {:ok, io} ->
        try do
          hash_io(io, 0, :crypto.hash_init(:sha256))
        after
          :file.close(io)
        end

      {:error, _} ->
        nil
    end
  end

  defp hash_io(io, size, hash) do
    case :file.read(io, @chunk) do
      {:ok, data} -> hash_io(io, size + byte_size(data), :crypto.hash_update(hash, data))
      :eof -> {size, hex(hash)}
      {:error, _} -> nil
    end
  end

  defp hex(hash), do: hash |> :crypto.hash_final() |> Base.encode16(case: :lower)

  defp open(path, modes) do
    case :file.open(path, [:raw, :binary | modes]) do
      {:ok, io} -> {:ok, io}
      {:error, reason} -> {:error, {:file, reason}}
    end
  end

  defp mkdir(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:file, reason}}
    end
  end
end
