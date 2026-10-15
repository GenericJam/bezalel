defmodule Bezalel.Test.Png do
  @moduledoc "PNGs made in tests: an 8-bit RGB picture of one color."

  @doc "A `width` × `height` PNG filled with `{r, g, b}`."
  @spec solid(pos_integer(), pos_integer(), {byte(), byte(), byte()}) :: binary()
  def solid(width, height, {r, g, b}) do
    row = [0 | List.duplicate([r, g, b], width)] |> IO.iodata_to_binary()
    pixels = :binary.copy(row, height)

    ihdr = <<width::32, height::32, 8, 2, 0, 0, 0>>

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", ihdr),
      chunk("IDAT", :zlib.compress(pixels)),
      chunk("IEND", "")
    ])
  end

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]
end

defmodule Bezalel.Test.PictureTool do
  @moduledoc "A tool that answers with a picture (a 1200 × 800 PNG) and a line of text."
  @behaviour Rho.Tool

  alias Bezalel.Test.Png

  @impl true
  def name, do: "draw_lampstand"

  @impl true
  def description, do: "Draws the lampstand."

  @impl true
  def parameter_schema, do: %{"type" => "object", "properties" => %{}}

  @impl true
  def run(_args, _ctx),
    do: {:ok, {:image, "image/png", Png.solid(1200, 800, {201, 160, 74}), "Drawn."}}
end
