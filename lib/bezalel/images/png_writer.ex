defmodule Bezalel.Images.PngWriter do
  @moduledoc """
  Streaming 8-bit RGB / RGBA PNG encoder: rows are deflated as they arrive
  (filter type 0), so the raw image is never held whole.

  The writer owns a `:zlib` stream; always `close/1` it (also after
  `finish/1`).
  """

  defstruct [:z, :width, :height, :channels, idat: []]

  @type t :: %__MODULE__{}

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>

  @spec new(pos_integer(), pos_integer(), 3 | 4) :: t()
  def new(width, height, channels) when channels in [3, 4] do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default)
    %__MODULE__{z: z, width: width, height: height, channels: channels}
  end

  @doc "Appends one row of `width * channels` bytes."
  @spec row(binary(), t()) :: t()
  def row(row, %__MODULE__{z: z, idat: idat} = w) do
    %{w | idat: [idat | :zlib.deflate(z, [0, row])]}
  end

  @doc "Flushes the stream and returns the PNG file."
  @spec finish(t()) :: binary()
  def finish(%__MODULE__{z: z, idat: idat} = w) do
    idat = [idat | :zlib.deflate(z, [], :finish)]
    :ok = :zlib.deflateEnd(z)
    color_type = if w.channels == 4, do: 6, else: 2

    IO.iodata_to_binary([
      @signature,
      chunk("IHDR", <<w.width::32, w.height::32, 8, color_type, 0, 0, 0>>),
      chunk("IDAT", IO.iodata_to_binary(idat)),
      chunk("IEND", <<>>)
    ])
  end

  @doc "Releases the zlib stream."
  @spec close(t()) :: :ok
  def close(%__MODULE__{z: z}), do: :zlib.close(z)

  defp chunk(type, data) do
    [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
  end
end
