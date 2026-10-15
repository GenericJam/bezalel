defmodule Bezalel.Images.Png do
  @moduledoc """
  Streaming PNG decoder feeding `Bezalel.Images.Resample`.

  Supports colour types 0/2/3/4/6 at every legal bit depth (1/2/4/8/16),
  PLTE + tRNS, and Adam7 interlacing. 16-bit samples keep their high byte.

  Memory: the IDAT payloads are inflated incrementally (`:zlib.safeInflate`),
  rows are unfiltered keeping only the previous row, converted to 8-bit
  pixels and folded straight into the resampler. A non-interlaced image
  therefore costs about one source row plus one destination row.

  Interlaced images are decoded pass by pass; each pass is a regular
  lattice of the image, so it is box-summed straight into destination-sized
  accumulators (one binary of 32- or 64-bit sums per destination row) which
  are finalized after the last pass. That costs `4..8 * channels` bytes per
  *destination* pixel, never a full-size bitmap.
  """

  import Bitwise

  alias Bezalel.Images.{PngWriter, Resample}

  @signature <<137, 80, 78, 71, 13, 10, 26, 10>>
  @adam7 [
    {0, 0, 8, 8},
    {4, 0, 8, 8},
    {0, 4, 4, 8},
    {2, 0, 4, 4},
    {0, 2, 2, 4},
    {1, 0, 2, 2},
    {0, 1, 1, 2}
  ]
  @valid %{0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16]}
  @samples %{0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4}

  @doc "Dimensions from the IHDR chunk."
  @spec info(binary()) :: {:ok, %{width: pos_integer(), height: pos_integer()}} | :error
  def info(<<@signature, _len::32, "IHDR", w::32, h::32, _::binary>>) when w > 0 and h > 0,
    do: {:ok, %{width: w, height: h}}

  def info(_png), do: :error

  @doc """
  Downscales to exactly `width` x `height` (the caller picks the size, see
  `Resample.fit/4`) and encodes an 8-bit RGB or RGBA PNG.
  """
  @spec thumbnail(binary(), pos_integer(), pos_integer()) ::
          {:ok, %{data: binary(), mime: String.t(), width: pos_integer(), height: pos_integer()}}
          | {:error, term()}
  def thumbnail(png, width, height) do
    with {:ok, image} <- parse(png) do
      writer = PngWriter.new(width, height, Resample.out_channels(image.channels))

      try do
        with {:ok, writer} <- run(image, width, height, {&PngWriter.row/2, writer}) do
          {:ok,
           %{data: PngWriter.finish(writer), mime: "image/png", width: width, height: height}}
        end
      after
        PngWriter.close(writer)
      end
    end
  end

  @doc """
  Fully decodes to 8-bit RGB (`channels: 3`) or RGBA (`channels: 4`) pixels.
  Holds the whole bitmap: meant for small images (and tests).
  """
  @spec decode(binary()) ::
          {:ok, %{width: pos_integer(), height: pos_integer(), channels: 3 | 4, pixels: binary()}}
          | {:error, term()}
  def decode(png) do
    with {:ok, image} <- parse(png),
         {:ok, rows} <- run(image, image.width, image.height, {&[&1 | &2], []}) do
      {:ok,
       %{
         width: image.width,
         height: image.height,
         channels: Resample.out_channels(image.channels),
         pixels: rows |> Enum.reverse() |> IO.iodata_to_binary()
       }}
    end
  end

  # -- header ---------------------------------------------------------------

  defp parse(
         <<@signature, 13::32, "IHDR", w::32, h::32, depth, ct, 0, 0, interlace, _crc::32,
           rest::binary>>
       )
       when w > 0 and h > 0 and interlace in [0, 1] do
    if depth in Map.get(@valid, ct, []) do
      rest
      |> chunks(%{plte: nil, trns: nil, idat: []})
      |> image(%{width: w, height: h, depth: depth, ct: ct, interlace: interlace})
    else
      {:error, {:unsupported_format, ct, depth}}
    end
  end

  defp parse(_png), do: {:error, :not_png}

  defp chunks(<<len::32, type::binary-4, data::binary-size(len), _crc::32, rest::binary>>, acc) do
    case type do
      "IEND" -> acc
      "IDAT" -> chunks(rest, %{acc | idat: [data | acc.idat]})
      "PLTE" -> chunks(rest, %{acc | plte: data})
      "tRNS" -> chunks(rest, %{acc | trns: data})
      _ -> chunks(rest, acc)
    end
  end

  # Truncated or missing IEND: decode what is there; missing rows are caught later.
  defp chunks(_rest, acc), do: acc

  defp image(%{idat: []}, _header), do: {:error, :no_image_data}
  defp image(%{ct: 3, plte: nil}, _header), do: {:error, :no_palette}

  defp image(chunks, %{ct: ct, depth: depth} = header) do
    bits = depth * Map.fetch!(@samples, ct)
    trns = transparency(ct, chunks.trns)

    {:ok,
     Map.merge(header, %{
       idat: Enum.reverse(chunks.idat),
       bits: bits,
       bpp: max(1, div(bits, 8)),
       trns: trns,
       palette: palette(ct, chunks.plte, trns),
       scale: gray_scale(depth),
       channels: native_channels(ct, trns != nil)
     })}
  end

  defp transparency(0, <<v::16, _::binary>>), do: v
  defp transparency(2, <<r::16, g::16, b::16, _::binary>>), do: {r, g, b}
  defp transparency(3, <<_, _::binary>> = alphas), do: alphas
  defp transparency(_ct, _trns), do: nil

  defp native_channels(0, false), do: 1
  defp native_channels(0, true), do: 2
  defp native_channels(4, _), do: 2
  defp native_channels(6, _), do: 4
  defp native_channels(_rgb, false), do: 3
  defp native_channels(_rgb, true), do: 4

  defp palette(3, plte, trns) do
    alphas = if is_binary(trns), do: trns, else: <<>>
    entries = for <<r, g, b <- plte>>, do: <<r, g, b>>

    entries
    |> Enum.with_index()
    |> Enum.map(fn {rgb, i} -> palette_entry(rgb, alphas, i, trns != nil) end)
    |> Kernel.++(
      List.duplicate(
        palette_entry(<<0, 0, 0>>, <<>>, 0, trns != nil),
        max(0, 256 - length(entries))
      )
    )
    |> List.to_tuple()
  end

  defp palette(_ct, _plte, _trns), do: nil

  defp palette_entry(rgb, _alphas, _i, false), do: rgb

  defp palette_entry(rgb, alphas, i, true) when i < byte_size(alphas),
    do: <<rgb::binary, :binary.at(alphas, i)>>

  defp palette_entry(rgb, _alphas, _i, true), do: <<rgb::binary, 255>>

  defp gray_scale(depth) when depth < 8 do
    max = (1 <<< depth) - 1
    List.to_tuple(for v <- 0..max, do: div(v * 255, max))
  end

  defp gray_scale(_depth), do: nil

  # -- streaming decode -----------------------------------------------------

  defp run(image, dw, dh, sink) do
    passes = passes(image, dw, dh)
    full_cols = Resample.spans(image.width, dw)
    full_rows = Resample.spans(image.height, dh)

    mode =
      if image.interlace == 1 do
        bits =
          if Resample.max_sum(full_cols, full_rows, image.channels) < 1 <<< 32, do: 32, else: 64

        {:store, bits, %{}}
      else
        :direct
      end

    st = start_pass(%{image: image, buf: <<>>, passes: passes, cur: nil, mode: mode, sink: sink})
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      st = Enum.reduce(image.idat, st, &inflate(z, :zlib.safeInflate(z, &1), &2))
      finish(st, full_cols, full_rows)
    catch
      {:image_error, reason} -> {:error, reason}
    after
      :zlib.close(z)
    end
  end

  defp inflate(z, {:continue, out}, st), do: inflate(z, :zlib.safeInflate(z, []), feed(st, out))
  defp inflate(_z, {:finished, out}, st), do: feed(st, out)
  defp inflate(_z, _other, _st), do: throw({:image_error, :zlib_dictionary})

  defp feed(%{cur: nil} = st, _out), do: st
  defp feed(st, []), do: st
  defp feed(%{buf: buf} = st, out), do: rows(%{st | buf: IO.iodata_to_binary([buf | out])})

  defp rows(%{cur: %{stride: stride} = cur, buf: buf} = st) when byte_size(buf) > stride do
    <<filter, raw::binary-size(^stride), rest::binary>> = buf
    line = unfilter(filter, raw, cur.prior, st.image.bpp)
    pixels = convert(line, cur.width, st.image)

    st =
      case Resample.push(cur.rs, pixels) do
        {:cont, rs} -> %{st | cur: %{cur | rs: rs}}
        {:emit, r, sums, count, rs} -> emit(%{st | cur: %{cur | rs: rs}}, r, sums, count)
      end

    st = %{st | buf: rest}

    case cur.left do
      1 -> rows(start_pass(st))
      left -> rows(%{st | cur: %{st.cur | left: left - 1, prior: line}})
    end
  end

  defp rows(st), do: st

  defp passes(%{interlace: 0} = image, dw, dh), do: [pass(image, {0, 0, 1, 1}, dw, dh)]

  defp passes(image, dw, dh) do
    @adam7
    |> Enum.map(&pass(image, &1, dw, dh))
    |> Enum.filter(&(&1.width > 0 and &1.height > 0))
  end

  defp pass(image, {x0, y0, dx, dy}, dw, dh) do
    width = lattice_count(image.width, x0, dx)
    height = lattice_count(image.height, y0, dy)

    %{
      width: width,
      height: height,
      stride: div(width * image.bits + 7, 8),
      cols: Resample.lattice_spans(image.width, dw, x0, dx, width),
      rows: Resample.lattice_spans(image.height, dh, y0, dy, height)
    }
  end

  defp lattice_count(size, origin, step) when size > origin,
    do: div(size - origin + step - 1, step)

  defp lattice_count(_size, _origin, _step), do: 0

  defp start_pass(%{passes: []} = st), do: %{st | cur: nil}

  defp start_pass(%{passes: [p | rest]} = st) do
    cur = %{
      left: p.height,
      width: p.width,
      stride: p.stride,
      cols: p.cols,
      prior: :binary.copy(<<0>>, p.stride),
      rs: Resample.new(p.cols, p.rows, st.image.channels)
    }

    %{st | passes: rest, cur: cur}
  end

  defp emit(%{mode: :direct, sink: {fun, acc}} = st, _r, sums, count) do
    row = Resample.finalize(sums, st.cur.cols, count, st.image.channels)
    %{st | sink: {fun, fun.(row, acc)}}
  end

  defp emit(%{mode: {:store, bits, store}} = st, r, sums, _count) do
    sums =
      case store do
        %{^r => stored} -> add_sums(bits, stored, sums, <<>>)
        _ -> encode_sums(sums, bits, <<>>)
      end

    %{st | mode: {:store, bits, Map.put(store, r, sums)}}
  end

  defp finish(%{cur: cur}, _cols, _rows) when cur != nil, do: {:error, :truncated}
  defp finish(%{mode: :direct, sink: {_fun, acc}}, _cols, _rows), do: {:ok, acc}

  defp finish(%{mode: {:store, bits, store}, sink: {fun, acc}, image: image}, cols, rows) do
    acc =
      rows
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {count, r}, acc ->
        sums = decode_sums(Map.fetch!(store, r), bits)
        fun.(Resample.finalize(sums, cols, count, image.channels), acc)
      end)

    {:ok, acc}
  end

  defp encode_sums([s | ss], bits, acc), do: encode_sums(ss, bits, <<acc::binary, s::size(bits)>>)
  defp encode_sums([], _bits, acc), do: acc

  defp add_sums(bits, stored, sums, acc) do
    stored
    |> decode_sums(bits)
    |> Enum.zip_with(sums, &+/2)
    |> encode_sums(bits, acc)
  end

  defp decode_sums(bin, bits), do: for(<<s::size(^bits) <- bin>>, do: s)

  # -- unfiltering ----------------------------------------------------------

  defp unfilter(0, raw, _prior, _bpp), do: raw

  defp unfilter(1, <<x1, x2, x3, rest::binary>>, _prior, 3),
    do: sub3(rest, <<x1, x2, x3>>, x1, x2, x3)

  defp unfilter(1, <<x1, x2, x3, x4, rest::binary>>, _prior, 4),
    do: sub4(rest, <<x1, x2, x3, x4>>, {x1, x2, x3, x4})

  defp unfilter(1, raw, _prior, bpp) do
    <<head::binary-size(^bpp), rest::binary>> = raw
    sub(rest, head, 0)
  end

  defp unfilter(2, raw, prior, _bpp), do: up(raw, prior, <<>>)

  defp unfilter(3, raw, prior, 3) do
    <<x1, x2, x3, rest::binary>> = raw
    <<b1, b2, b3, prest::binary>> = prior
    a = {x1 + (b1 >>> 1) &&& 255, x2 + (b2 >>> 1) &&& 255, x3 + (b3 >>> 1) &&& 255}
    avg3(rest, prest, <<elem(a, 0), elem(a, 1), elem(a, 2)>>, a)
  end

  defp unfilter(3, raw, prior, 4) do
    <<x1, x2, x3, x4, rest::binary>> = raw
    <<b1, b2, b3, b4, prest::binary>> = prior

    {a1, a2, a3, a4} =
      {x1 + (b1 >>> 1) &&& 255, x2 + (b2 >>> 1) &&& 255, x3 + (b3 >>> 1) &&& 255,
       x4 + (b4 >>> 1) &&& 255}

    avg4(rest, prest, <<a1, a2, a3, a4>>, {a1, a2, a3, a4})
  end

  defp unfilter(3, raw, prior, bpp) do
    <<head::binary-size(^bpp), rest::binary>> = raw
    <<phead::binary-size(^bpp), prest::binary>> = prior
    average(rest, prest, half_up(head, phead, <<>>), 0)
  end

  defp unfilter(4, raw, prior, 3) do
    <<x1, x2, x3, rest::binary>> = raw
    <<c1, c2, c3, prest::binary>> = prior
    a = {x1 + c1 &&& 255, x2 + c2 &&& 255, x3 + c3 &&& 255}
    paeth3(rest, prest, <<elem(a, 0), elem(a, 1), elem(a, 2)>>, a, {c1, c2, c3})
  end

  defp unfilter(4, raw, prior, 4) do
    <<x1, x2, x3, x4, rest::binary>> = raw
    <<c1, c2, c3, c4, prest::binary>> = prior
    {a1, a2, a3, a4} = {x1 + c1 &&& 255, x2 + c2 &&& 255, x3 + c3 &&& 255, x4 + c4 &&& 255}
    paeth4(rest, prest, <<a1, a2, a3, a4>>, {a1, a2, a3, a4}, {c1, c2, c3, c4})
  end

  defp unfilter(4, raw, prior, bpp) do
    <<head::binary-size(^bpp), rest::binary>> = raw
    <<phead::binary-size(^bpp), prest::binary>> = prior
    paeth(rest, prest, up(head, phead, <<>>), prior, 0)
  end

  defp unfilter(_filter, _raw, _prior, _bpp), do: throw({:image_error, :bad_filter})

  defp sub(<<x, rest::binary>>, acc, i),
    do: sub(rest, <<acc::binary, x + :binary.at(acc, i)>>, i + 1)

  defp sub(<<>>, acc, _i), do: acc

  # Byte-wise add of 7 bytes at a time (SWAR), staying within small integers.
  @low7 0x7F7F7F7F7F7F7F
  @high 0x80808080808080

  defp up(<<x::56, rest::binary>>, <<b::56, prior::binary>>, acc) do
    sum = bxor((x &&& @low7) + (b &&& @low7), bxor(x, b) &&& @high)
    up(rest, prior, <<acc::binary, sum::56>>)
  end

  defp up(<<x, rest::binary>>, <<b, prior::binary>>, acc),
    do: up(rest, prior, <<acc::binary, x + b>>)

  defp up(<<>>, _prior, acc), do: acc

  defp sub3(<<x1, x2, x3, rest::binary>>, acc, a1, a2, a3) do
    {v1, v2, v3} = {x1 + a1 &&& 255, x2 + a2 &&& 255, x3 + a3 &&& 255}
    sub3(rest, <<acc::binary, v1, v2, v3>>, v1, v2, v3)
  end

  defp sub3(_rest, acc, _a1, _a2, _a3), do: acc

  defp sub4(<<x1, x2, x3, x4, rest::binary>>, acc, {a1, a2, a3, a4}) do
    v = {x1 + a1 &&& 255, x2 + a2 &&& 255, x3 + a3 &&& 255, x4 + a4 &&& 255}
    sub4(rest, <<acc::binary, elem(v, 0), elem(v, 1), elem(v, 2), elem(v, 3)>>, v)
  end

  defp sub4(_rest, acc, _a), do: acc

  defp avg3(<<x1, x2, x3, rest::binary>>, <<b1, b2, b3, prest::binary>>, acc, {a1, a2, a3}) do
    v1 = x1 + ((a1 + b1) >>> 1) &&& 255
    v2 = x2 + ((a2 + b2) >>> 1) &&& 255
    v3 = x3 + ((a3 + b3) >>> 1) &&& 255
    avg3(rest, prest, <<acc::binary, v1, v2, v3>>, {v1, v2, v3})
  end

  defp avg3(_rest, _prest, acc, _a), do: acc

  defp avg4(
         <<x1, x2, x3, x4, rest::binary>>,
         <<b1, b2, b3, b4, prest::binary>>,
         acc,
         {a1, a2, a3, a4}
       ) do
    v1 = x1 + ((a1 + b1) >>> 1) &&& 255
    v2 = x2 + ((a2 + b2) >>> 1) &&& 255
    v3 = x3 + ((a3 + b3) >>> 1) &&& 255
    v4 = x4 + ((a4 + b4) >>> 1) &&& 255
    avg4(rest, prest, <<acc::binary, v1, v2, v3, v4>>, {v1, v2, v3, v4})
  end

  defp avg4(_rest, _prest, acc, _a), do: acc

  defp half_up(<<x, rest::binary>>, <<b, prior::binary>>, acc),
    do: half_up(rest, prior, <<acc::binary, x + (b >>> 1)>>)

  defp half_up(<<>>, _prior, acc), do: acc

  defp average(<<x, rest::binary>>, <<b, prior::binary>>, acc, i),
    do: average(rest, prior, <<acc::binary, x + ((:binary.at(acc, i) + b) >>> 1)>>, i + 1)

  defp average(<<>>, _prior, acc, _i), do: acc

  defp paeth(<<x, rest::binary>>, <<b, prior_rest::binary>>, acc, prior, i) do
    p = predict(:binary.at(acc, i), b, :binary.at(prior, i))
    paeth(rest, prior_rest, <<acc::binary, x + p>>, prior, i + 1)
  end

  defp paeth(<<>>, _prior_rest, acc, _prior, _i), do: acc

  # bpp 3/4 (8-bit RGB/RGBA): a whole pixel per step, the left (a) and
  # upper-left (c) pixel riding along as tuples.
  defp paeth3(<<x1, x2, x3, rest::binary>>, <<b1, b2, b3, prest::binary>>, acc, {a1, a2, a3}, c) do
    {c1, c2, c3} = c
    v1 = x1 + predict(a1, b1, c1) &&& 255
    v2 = x2 + predict(a2, b2, c2) &&& 255
    v3 = x3 + predict(a3, b3, c3) &&& 255
    paeth3(rest, prest, <<acc::binary, v1, v2, v3>>, {v1, v2, v3}, {b1, b2, b3})
  end

  defp paeth3(_rest, _prest, acc, _a, _c), do: acc

  defp paeth4(
         <<x1, x2, x3, x4, rest::binary>>,
         <<b1, b2, b3, b4, prest::binary>>,
         acc,
         {a1, a2, a3, a4},
         c
       ) do
    {c1, c2, c3, c4} = c
    v1 = x1 + predict(a1, b1, c1) &&& 255
    v2 = x2 + predict(a2, b2, c2) &&& 255
    v3 = x3 + predict(a3, b3, c3) &&& 255
    v4 = x4 + predict(a4, b4, c4) &&& 255
    paeth4(rest, prest, <<acc::binary, v1, v2, v3, v4>>, {v1, v2, v3, v4}, {b1, b2, b3, b4})
  end

  defp paeth4(_rest, _prest, acc, _a, _c), do: acc

  defp predict(a, b, c) do
    pa = abs(b - c)
    pb = abs(a - c)
    pc = abs(a + b - 2 * c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  # -- sample conversion to 8-bit pixels -------------------------------------

  defp convert(line, width, %{ct: 3, depth: 8, palette: pal}),
    do: line |> binary_part(0, width) |> palette_row(pal)

  defp convert(line, width, %{ct: 3, depth: d, palette: pal} = image) do
    row = for <<i::size(^d) <- line>>, into: <<>>, do: elem(pal, i)
    binary_part(row, 0, width * image.channels)
  end

  defp convert(line, _width, %{depth: 8, trns: nil}), do: line

  defp convert(line, _width, %{depth: 16, trns: nil}),
    do: for(<<h, _::8 <- line>>, into: <<>>, do: <<h>>)

  defp convert(line, width, %{ct: 0, depth: d, trns: nil, scale: scale}) do
    row = for <<v::size(^d) <- line>>, into: <<>>, do: <<elem(scale, v)>>
    binary_part(row, 0, width)
  end

  defp convert(line, width, %{ct: 0, depth: d, trns: t, scale: scale}) when d < 8 do
    row = for <<v::size(^d) <- line>>, into: <<>>, do: <<elem(scale, v), alpha(v, t)>>
    binary_part(row, 0, 2 * width)
  end

  defp convert(line, _width, %{ct: 0, depth: 8, trns: t}),
    do: for(<<v <- line>>, into: <<>>, do: <<v, alpha(v, t)>>)

  defp convert(line, _width, %{ct: 0, depth: 16, trns: t}),
    do: for(<<v::16 <- line>>, into: <<>>, do: <<v >>> 8, alpha(v, t)>>)

  defp convert(line, _width, %{ct: 2, depth: 8, trns: t}),
    do: for(<<r, g, b <- line>>, into: <<>>, do: <<r, g, b, alpha({r, g, b}, t)>>)

  defp convert(line, _width, %{ct: 2, depth: 16, trns: t}) do
    for <<r::16, g::16, b::16 <- line>>,
      into: <<>>,
      do: <<r >>> 8, g >>> 8, b >>> 8, alpha({r, g, b}, t)>>
  end

  defp palette_row(line, pal), do: for(<<i <- line>>, into: <<>>, do: elem(pal, i))

  defp alpha(t, t), do: 0
  defp alpha(_v, _t), do: 255
end
