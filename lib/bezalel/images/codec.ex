defmodule Bezalel.Images.Codec do
  @moduledoc """
  Pure-Elixir image sniffing and thumbnailing, built to run on the phone's
  BEAM (no NIFs) without ever holding a full-size decoded bitmap.

    * `info/1` reads the dimensions of PNG, JPEG (EXIF orientation applied),
      GIF, WebP (VP8/VP8L/VP8X) and HEIF/HEIC files (largest `ispe`
      property, swapped for a 90/270 degree `irot`). AVIF reports
      `format: :unknown` with its size.
    * `thumbnail/3` fits an image inside a box (aspect kept, never
      upscaled), using area averaging. PNG is decoded in a streaming pass
      (`Bezalel.Images.Png`); baseline JPEG at the smallest of 1/8,
      1/4, 1/2 and 1/1 scale that covers the box, by a scaled IDCT
      (`Bezalel.Images.Jpeg`). Output is always an 8-bit
      PNG, RGBA when the source has alpha.

  Anything already inside the box, or a format/variant that can't be
  decoded here (GIF, WebP, HEIC, progressive/arithmetic JPEG...) but whose
  size is known, comes back as `{:original, dims}`: show the original bytes.
  """

  alias Bezalel.Images.{Jpeg, Png, Resample}

  @type format :: :png | :jpeg | :gif | :webp | :heic | :unknown
  @type dims :: %{width: pos_integer(), height: pos_integer()}

  @heif_brands ~w(heic heix hevc hevx heim heis mif1 msf1)
  @avif_brands ~w(avif avis)

  @doc "Format and (displayed) dimensions, or `:error` when unrecognised."
  @spec info(binary()) ::
          {:ok, %{format: format(), width: pos_integer(), height: pos_integer()}} | :error
  def info(<<137, "PNG", _::binary>> = bin), do: tag(Png.info(bin), :png)
  def info(<<0xFF, 0xD8, _::binary>> = bin), do: tag(Jpeg.info(bin), :jpeg)

  def info(<<"GIF8", v, "a", w::little-16, h::little-16, _::binary>>) when v in [?7, ?9],
    do: dims(:gif, w, h)

  def info(<<"RIFF", _size::32, "WEBP", chunk::binary>>), do: webp(chunk)
  def info(<<_size::32, "ftyp", brand::binary-4, _::binary>> = bin), do: heif(bin, brand)
  def info(_bin), do: :error

  @doc """
  A thumbnail fitting `max_width` x `max_height`; see the moduledoc.
  """
  @spec thumbnail(binary(), pos_integer(), pos_integer()) ::
          {:ok, %{data: binary(), mime: String.t(), width: pos_integer(), height: pos_integer()}}
          | {:original, dims()}
          | {:error, term()}
  def thumbnail(bin, max_width, max_height)
      when is_binary(bin) and is_integer(max_width) and max_width > 0 and is_integer(max_height) and
             max_height > 0 do
    case info(bin) do
      {:ok, %{width: w, height: h}} when w <= max_width and h <= max_height ->
        {:original, %{width: w, height: h}}

      {:ok, %{format: format, width: w, height: h}} ->
        decode(format, bin, %{width: w, height: h}, max_width, max_height)

      :error ->
        {:error, :unrecognized}
    end
  end

  defp decode(:png, bin, dims, max_width, max_height) do
    {w, h} = Resample.fit(dims.width, dims.height, max_width, max_height)
    guard(fn -> Png.thumbnail(bin, w, h) end)
  end

  defp decode(:jpeg, bin, dims, max_width, max_height) do
    case guard(fn -> Jpeg.thumbnail(bin, max_width, max_height) end) do
      :unsupported -> {:original, dims}
      result -> result
    end
  end

  defp decode(_format, _bin, dims, _max_width, _max_height), do: {:original, dims}

  # Corrupt input must never crash the caller.
  defp guard(fun) do
    fun.()
  rescue
    e in [
      ErlangError,
      MatchError,
      CaseClauseError,
      FunctionClauseError,
      ArgumentError,
      ArithmeticError,
      KeyError
    ] ->
      {:error, {:corrupt, Exception.message(e)}}
  catch
    {:image_error, reason} -> {:error, reason}
  end

  defp tag({:ok, %{width: w, height: h}}, format), do: dims(format, w, h)
  defp tag(:error, _format), do: :error

  defp dims(format, w, h) when w > 0 and h > 0, do: {:ok, %{format: format, width: w, height: h}}
  defp dims(_format, _w, _h), do: :error

  # -- WebP -----------------------------------------------------------------

  defp webp(
         <<"VP8 ", _len::32, _tag::24, 0x9D, 0x01, 0x2A, w::little-16, h::little-16, _::binary>>
       ),
       do: dims(:webp, Bitwise.band(w, 0x3FFF), Bitwise.band(h, 0x3FFF))

  defp webp(<<"VP8L", _len::32, 0x2F, bits::little-32, _::binary>>) do
    dims(:webp, Bitwise.band(bits, 0x3FFF) + 1, Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1)
  end

  defp webp(<<"VP8X", _len::32, _flags::32, w::little-24, h::little-24, _::binary>>),
    do: dims(:webp, w + 1, h + 1)

  defp webp(_chunk), do: :error

  # -- HEIF / HEIC / AVIF -----------------------------------------------------

  defp heif(bin, brand) do
    format =
      cond do
        brand in @heif_brands -> :heic
        brand in @avif_brands -> :unknown
        true -> nil
      end

    with true <- format != nil,
         {:ok, meta} <- find_box(bin, "meta"),
         <<_version_flags::32, meta::binary>> <- meta,
         {:ok, iprp} <- find_box(meta, "iprp"),
         {:ok, ipco} <- find_box(iprp, "ipco"),
         {w, h} <- largest_ispe(ipco) do
      if rotated?(ipco), do: dims(format, h, w), else: dims(format, w, h)
    else
      _ -> :error
    end
  end

  defp boxes(<<size::32, type::binary-4, rest::binary>>)
       when size >= 8 and byte_size(rest) >= size - 8 do
    payload_size = size - 8
    <<payload::binary-size(^payload_size), rest::binary>> = rest
    [{type, payload} | boxes(rest)]
  end

  defp boxes(<<1::32, type::binary-4, size::64, rest::binary>>)
       when size >= 16 and byte_size(rest) >= size - 16 do
    payload_size = size - 16
    <<payload::binary-size(^payload_size), rest::binary>> = rest
    [{type, payload} | boxes(rest)]
  end

  defp boxes(<<0::32, type::binary-4, rest::binary>>), do: [{type, rest}]
  defp boxes(_rest), do: []

  defp find_box(bin, type) do
    case List.keyfind(boxes(bin), type, 0) do
      {^type, payload} -> {:ok, payload}
      nil -> :error
    end
  end

  defp largest_ispe(ipco) do
    sizes =
      for {"ispe", <<_vf::32, w::32, h::32, _::binary>>} <- boxes(ipco),
          w > 0 and h > 0,
          do: {w, h}

    if sizes == [], do: :error, else: Enum.max_by(sizes, fn {w, h} -> w * h end)
  end

  defp rotated?(ipco) do
    case List.keyfind(boxes(ipco), "irot", 0) do
      {"irot", <<angle, _::binary>>} -> Bitwise.band(angle, 1) == 1
      nil -> false
    end
  end
end
