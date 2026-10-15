defmodule Bezalel.Images.CodecTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Bezalel.Images.{Codec, Png}

  @fixtures Path.expand("../../fixtures/images", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  # -- a tiny PNG encoder (any colour type / depth, cycling all five filters) --

  defp png(width, height, ct, depth, pixel, opts \\ []) do
    channels = %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}[ct]
    bpp = max(1, div(channels * depth, 8))

    rows =
      for y <- 0..(height - 1) do
        for(x <- 0..(width - 1), s <- pixel.(x, y), into: <<>>, do: <<s::size(depth)>>) |> pad()
      end

    {filtered, _prior} =
      rows
      |> Enum.with_index()
      |> Enum.map_reduce(:binary.copy(<<0>>, byte_size(hd(rows))), fn {row, y}, prior ->
        f = rem(y, 5)
        {[f | filter(f, :binary.bin_to_list(row), :binary.bin_to_list(prior), bpp)], row}
      end)

    ihdr = <<width::32, height::32, depth, ct, 0, 0, Keyword.get(opts, :interlace, 0)>>

    IO.iodata_to_binary([
      <<137, 80, 78, 71, 13, 10, 26, 10>>,
      chunk("IHDR", ihdr),
      if(opts[:plte], do: chunk("PLTE", opts[:plte]), else: []),
      if(opts[:trns], do: chunk("tRNS", opts[:trns]), else: []),
      chunk("IDAT", :zlib.compress(filtered)),
      chunk("IEND", <<>>)
    ])
  end

  defp pad(row) when rem(bit_size(row), 8) == 0, do: row
  defp pad(row), do: pad(<<row::bitstring, 0::1>>)

  defp chunk(type, data),
    do: [<<byte_size(data)::32>>, type, data, <<:erlang.crc32([type, data])::32>>]

  defp filter(f, row, prior, bpp) do
    left = List.duplicate(0, bpp) ++ row
    upleft = List.duplicate(0, bpp) ++ prior

    [row, left, prior, upleft]
    |> Enum.zip()
    |> Enum.map(fn {x, a, b, c} -> x - predictor(f, a, b, c) &&& 255 end)
  end

  defp predictor(0, _a, _b, _c), do: 0
  defp predictor(1, a, _b, _c), do: a
  defp predictor(2, _a, b, _c), do: b
  defp predictor(3, a, b, _c), do: div(a + b, 2)

  defp predictor(4, a, b, c) do
    p = a + b - c
    {pa, pb, pc} = {abs(p - a), abs(p - b), abs(p - c)}

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # An 8x4 image whose left half is `left` and right half a checkerboard of
  # `on` / `off`: thumbnailed to 2x1, the right pixel is the average.
  defp halves(left, on, off), do: &half_pixel(&1, &2, left, on, off)

  defp half_pixel(x, _y, left, _on, _off) when x < 4, do: left
  defp half_pixel(x, y, _left, on, _off) when rem(x + y, 2) == 0, do: on
  defp half_pixel(_x, _y, _left, _on, off), do: off

  defp thumb_pixels(png_bin) do
    assert {:ok, %{width: 2, height: 1, mime: "image/png", data: data}} =
             Codec.thumbnail(png_bin, 2, 2)

    assert {:ok, %{width: 2, height: 1} = decoded} = Png.decode(data)
    {decoded.channels, :binary.bin_to_list(decoded.pixels)}
  end

  describe "PNG round trips" do
    test "grayscale at every bit depth" do
      for depth <- [1, 2, 4, 8, 16] do
        max = (1 <<< depth) - 1
        bin = png(8, 4, 0, depth, halves([max], [0], [max]))
        assert thumb_pixels(bin) == {3, [255, 255, 255, 128, 128, 128]}, "depth #{depth}"
      end
    end

    test "truecolour 8 and 16 bit" do
      for depth <- [8, 16] do
        m = (1 <<< depth) - 1
        bin = png(8, 4, 2, depth, halves([m, 0, 0], [0, m, 0], [0, 0, m]))
        assert thumb_pixels(bin) == {3, [255, 0, 0, 0, 128, 128]}, "depth #{depth}"
      end
    end

    test "palette at every bit depth" do
      for depth <- [1, 2, 4, 8] do
        bin = png(8, 4, 3, depth, halves([0], [0], [1]), plte: <<255, 0, 0, 0, 0, 255>>)
        assert thumb_pixels(bin) == {3, [255, 0, 0, 128, 0, 128]}, "depth #{depth}"
      end
    end

    test "palette with tRNS keeps alpha and ignores transparent colour" do
      bin =
        png(8, 4, 3, 4, halves([0], [0], [1]), plte: <<255, 0, 0, 0, 0, 255>>, trns: <<255, 0>>)

      assert thumb_pixels(bin) == {4, [255, 0, 0, 255, 255, 0, 0, 128]}
    end

    test "gray + alpha and RGBA, 8 and 16 bit" do
      for depth <- [8, 16] do
        m = (1 <<< depth) - 1
        s = &div(&1 * m, 255)

        ga = png(8, 4, 4, depth, halves([s.(200), m], [m, m], [0, 0]))
        assert thumb_pixels(ga) == {4, [200, 200, 200, 255, 255, 255, 255, 128]}, "GA #{depth}"

        rgba = png(8, 4, 6, depth, halves([0, m, 0, m], [m, 0, m, m], [0, m, 0, 0]))
        assert thumb_pixels(rgba) == {4, [0, 255, 0, 255, 255, 0, 255, 128]}, "RGBA #{depth}"
      end
    end

    test "tRNS on grayscale and truecolour" do
      gray = png(8, 4, 0, 8, halves([255], [255], [7]), trns: <<7::16>>)
      assert thumb_pixels(gray) == {4, [255, 255, 255, 255, 255, 255, 255, 128]}

      rgb =
        png(8, 4, 2, 16, halves([0, 0, 65_535], [0, 0, 65_535], [1, 2, 3]),
          trns: <<1::16, 2::16, 3::16>>
        )

      assert thumb_pixels(rgb) == {4, [0, 0, 255, 255, 0, 0, 255, 128]}
    end

    test "non-integer ratios average the covered area" do
      # 5x1: 0, 0, 255, 255, 255 -> 2 columns covering 2 and 3 source pixels.
      bin = png(5, 1, 0, 8, fn x, _y -> [if(x < 2, do: 0, else: 255)] end)
      assert {:ok, %{width: 2, height: 1, data: data}} = Codec.thumbnail(bin, 2, 10)
      assert {:ok, %{pixels: <<0, 0, 0, 255, 255, 255>>}} = Png.decode(data)
    end

    test "Adam7 interlaced decodes exactly like its non-interlaced twin" do
      plain = fixture("gradient.png")
      interlaced = fixture("gradient_interlaced.png")

      assert {:ok, a} = Png.decode(plain)
      assert {:ok, b} = Png.decode(interlaced)
      assert a == b
      assert %{width: 37, height: 23, channels: 4} = a

      assert {:ok, %{width: 10, height: 6} = t1} = Codec.thumbnail(plain, 10, 10)
      assert {:ok, t2} = Codec.thumbnail(interlaced, 10, 10)
      assert t1 == t2
    end

    test "interlaced image built in-test, sub-8-bit with tiny passes" do
      pixel = fn x, y -> [rem(x * 3 + y, 4)] end
      plain = png(9, 7, 0, 2, pixel)

      # Re-encode the same pixels Adam7-interlaced by hand.
      passes = [
        {0, 0, 8, 8},
        {4, 0, 8, 8},
        {0, 4, 4, 8},
        {2, 0, 4, 4},
        {0, 2, 2, 4},
        {1, 0, 2, 2},
        {0, 1, 1, 2}
      ]

      raw =
        passes
        |> Enum.flat_map(fn {x0, y0, dx, dy} ->
          xs = Enum.take_every(x0..8//1, dx)
          ys = Enum.take_every(y0..6//1, dy)
          if xs == [], do: [], else: Enum.map(ys, &interlaced_row(xs, &1, pixel))
        end)
        |> IO.iodata_to_binary()

      interlaced =
        IO.iodata_to_binary([
          <<137, 80, 78, 71, 13, 10, 26, 10>>,
          chunk("IHDR", <<9::32, 7::32, 2, 0, 0, 0, 1>>),
          chunk("IDAT", :zlib.compress(raw)),
          chunk("IEND", <<>>)
        ])

      assert Png.decode(plain) == Png.decode(interlaced)
      assert Codec.thumbnail(plain, 4, 4) == Codec.thumbnail(interlaced, 4, 4)
    end

    test "output PNG chunks carry valid CRCs" do
      {:ok, %{data: <<_sig::binary-8, rest::binary>>}} =
        Codec.thumbnail(fixture("gradient.png"), 5, 5)

      for {type, data, crc} <- chunks(rest) do
        assert crc == :erlang.crc32([type, data])
      end
    end

    defp interlaced_row(xs, y, pixel) do
      <<0, pad(for(x <- xs, s <- pixel.(x, y), into: <<>>, do: <<s::2>>))::binary>>
    end
  end

  defp chunks(<<len::32, type::binary-4, data::binary-size(len), crc::32, rest::binary>>),
    do: [{type, data, crc} | chunks(rest)]

  defp chunks(<<>>), do: []

  describe "fits and errors" do
    test "an image already inside the box is left alone" do
      assert {:original, %{width: 37, height: 23}} =
               Codec.thumbnail(fixture("gradient.png"), 37, 100)

      assert {:original, %{width: 160, height: 120}} =
               Codec.thumbnail(fixture("quads_420.jpg"), 160, 120)
    end

    test "corrupt or unknown data" do
      assert {:error, _} = Codec.thumbnail("not an image at all", 10, 10)
      assert :error = Codec.info(<<0, 1, 2, 3>>)

      good = fixture("gradient.png")
      # Cut inside the IDAT chunk: header parses, rows run out.
      assert {:error, _} = Codec.thumbnail(binary_part(good, 0, 200), 5, 5)

      # Garbage zlib stream.
      bad_zlib =
        IO.iodata_to_binary([
          <<137, 80, 78, 71, 13, 10, 26, 10>>,
          chunk("IHDR", <<64::32, 64::32, 8, 2, 0, 0, 0>>),
          chunk("IDAT", :binary.copy(<<0xAB>>, 100)),
          chunk("IEND", <<>>)
        ])

      assert {:error, _} = Codec.thumbnail(bad_zlib, 5, 5)

      # Bad filter type.
      bad_filter =
        IO.iodata_to_binary([
          <<137, 80, 78, 71, 13, 10, 26, 10>>,
          chunk("IHDR", <<4::32, 4::32, 8, 0, 0, 0, 0>>),
          chunk("IDAT", :zlib.compress(:binary.copy(<<9, 1, 2, 3, 4>>, 4))),
          chunk("IEND", <<>>)
        ])

      assert {:error, :bad_filter} = Codec.thumbnail(bad_filter, 2, 2)

      jpeg = fixture("quads_420.jpg")
      assert {:error, _} = Codec.thumbnail(binary_part(jpeg, 0, 300), 5, 5)
    end
  end

  describe "JPEG" do
    defp rgb_at(%{data: data, width: w}, x, y) do
      {:ok, %{pixels: px}} = Png.decode(data)
      :binary.bin_to_list(px, (y * w + x) * 3, 3)
    end

    defp near?(actual, expected),
      do: Enum.zip(actual, expected) |> Enum.all?(fn {a, e} -> abs(a - e) <= 24 end)

    test "baseline with 4:2:0, 4:2:2, 4:4:4 and restart markers decodes at 1/8 scale" do
      for name <- ~w(quads_420.jpg quads_422.jpg quads_444.jpg quads_restart.jpg) do
        assert {:ok, %{width: 20, height: 15, mime: "image/png"} = t} =
                 Codec.thumbnail(fixture(name), 100, 100)

        assert near?(rgb_at(t, 2, 2), [255, 0, 0]), name
        assert near?(rgb_at(t, 17, 2), [0, 255, 0]), name
        assert near?(rgb_at(t, 2, 12), [0, 0, 255]), name
        assert near?(rgb_at(t, 17, 12), [255, 255, 255]), name
      end
    end

    test "1/8 image still too large is box-downscaled" do
      assert {:ok, %{width: 10, height: 8} = t} =
               Codec.thumbnail(fixture("quads_420.jpg"), 10, 10)

      assert near?(rgb_at(t, 0, 0), [255, 0, 0])
      assert near?(rgb_at(t, 9, 7), [255, 255, 255])
    end

    test "grayscale" do
      assert {:ok, %{format: :jpeg, width: 96, height: 64}} = Codec.info(fixture("gray.jpg"))
      assert {:ok, %{width: 12, height: 8} = t} = Codec.thumbnail(fixture("gray.jpg"), 50, 50)
      assert near?(rgb_at(t, 1, 4), [40, 40, 40])
      assert near?(rgb_at(t, 10, 4), [200, 200, 200])
    end

    test "EXIF orientation 6 is applied to info and thumbnail" do
      # Stored 160x80, left half red, right half blue; displayed rotated 90 CW.
      assert {:ok, %{width: 80, height: 160}} = Codec.info(fixture("orient6.jpg"))
      assert {:ok, %{width: 10, height: 20} = t} = Codec.thumbnail(fixture("orient6.jpg"), 50, 50)
      assert near?(rgb_at(t, 5, 2), [255, 0, 0])
      assert near?(rgb_at(t, 5, 17), [0, 0, 255])
    end

    test "progressive is left to the platform" do
      assert {:ok, %{format: :jpeg, width: 160, height: 120}} =
               Codec.info(fixture("quads_progressive.jpg"))

      assert {:original, %{width: 160, height: 120}} =
               Codec.thumbnail(fixture("quads_progressive.jpg"), 50, 50)
    end
  end

  describe "other formats report their size" do
    test "GIF, WebP and HEIC" do
      gif = <<"GIF89a", 300::little-16, 200::little-16, 0::64>>
      assert {:ok, %{format: :gif, width: 300, height: 200}} = Codec.info(gif)
      assert {:original, %{width: 300, height: 200}} = Codec.thumbnail(gif, 10, 10)

      vp8 =
        <<"RIFF", 0::32, "WEBP", "VP8 ", 0::32, 0::24, 0x9D, 0x01, 0x2A, 640::little-16,
          480::little-16>>

      assert {:ok, %{format: :webp, width: 640, height: 480}} = Codec.info(vp8)

      bits = 639 ||| 479 <<< 14
      vp8l = <<"RIFF", 0::32, "WEBP", "VP8L", 0::32, 0x2F, bits::little-32>>
      assert {:ok, %{format: :webp, width: 640, height: 480}} = Codec.info(vp8l)

      vp8x = <<"RIFF", 0::32, "WEBP", "VP8X", 10::32, 0::32, 1919::little-24, 1079::little-24>>
      assert {:ok, %{format: :webp, width: 1920, height: 1080}} = Codec.info(vp8x)

      box = fn type, payload -> <<byte_size(payload) + 8::32, type::binary, payload::binary>> end
      ispe = fn w, h -> box.("ispe", <<0::32, w::32, h::32>>) end
      ipco = box.("ipco", ispe.(512, 512) <> ispe.(4032, 3024) <> box.("irot", <<1>>))

      heic =
        box.("ftyp", "heic" <> <<0::32>> <> "mif1") <>
          box.("meta", <<0::32>> <> box.("iprp", ipco))

      assert {:ok, %{format: :heic, width: 3024, height: 4032}} = Codec.info(heic)
      assert {:original, %{width: 3024, height: 4032}} = Codec.thumbnail(heic, 100, 100)
    end
  end

  describe "large images" do
    test "a 4000x3000 PNG thumbnails in bounded memory" do
      z = :zlib.open()
      :ok = :zlib.deflateInit(z, 9)
      row = [0 | :binary.copy(<<10, 120, 230>>, 4000)]
      idat = Enum.map(1..3000, fn _ -> :zlib.deflate(z, row) end)
      idat = IO.iodata_to_binary([idat | :zlib.deflate(z, [], :finish)])
      :zlib.close(z)

      bin =
        IO.iodata_to_binary([
          <<137, 80, 78, 71, 13, 10, 26, 10>>,
          chunk("IHDR", <<4000::32, 3000::32, 8, 2, 0, 0, 0>>),
          chunk("IDAT", idat),
          chunk("IEND", <<>>)
        ])

      parent = self()

      # The decoded bitmap alone would be 36 MB; cap the worker at 16 MB
      # (heap + referenced binaries) and let the VM kill it if it bloats.
      {pid, ref} =
        spawn_monitor(fn ->
          Process.flag(:max_heap_size, %{
            size: 2_000_000,
            kill: true,
            error_logger: false,
            include_shared_binaries: true
          })

          {us, result} = :timer.tc(fn -> Codec.thumbnail(bin, 1080, 1080) end)
          send(parent, {:done, us, result})
        end)

      assert_receive {:done, us, {:ok, %{width: 1080, height: 810} = t}}, 60_000
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert us < 30_000_000
      assert rgb_at(t, 540, 400) == [10, 120, 230]
    end
  end
end
