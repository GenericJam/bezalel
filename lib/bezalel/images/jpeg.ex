defmodule Bezalel.Images.Jpeg do
  @moduledoc """
  JPEG header parsing and a 1/8-scale "DC only" baseline decoder.

  `info/1` walks the markers up to the frame header (SOF0..SOF15) and reads
  the EXIF orientation (APP1, IFD0 tag 0x0112) on the way; dimensions are
  reported as displayed, i.e. swapped for orientations 5-8.

  `thumbnail/3` decodes baseline Huffman JPEGs (SOF0/SOF1, 8-bit, one
  interleaved scan holding every component, or a single-component
  grayscale scan). Every 8x8 block's average colour is its DC coefficient,
  so only the DC values are kept; AC codes are entropy-decoded just to be
  skipped. That yields the image at 1/8 scale without any IDCT. Restart
  intervals (DRI/RSTn), 0xFF00 stuffing, any H/V chroma subsampling
  (nearest-sample upsampling) and grayscale are handled. One MCU row of DC
  values is held at a time; the 1/8 rows stream through
  `Bezalel.Images.Resample` into the PNG writer. Only for EXIF orientations
  other than 1 is the (already small) destination image collected and
  re-oriented before encoding.

  Progressive, lossless, arithmetic-coded, 12-bit, CMYK/4-component and
  multi-scan baseline files return `:unsupported` (the caller shows the
  original).
  """

  import Bitwise

  alias Bezalel.Images.{PngWriter, Resample}

  @doc "Displayed dimensions (EXIF orientation applied)."
  @spec info(binary()) :: {:ok, %{width: pos_integer(), height: pos_integer()}} | :error
  def info(<<0xFF, 0xD8, rest::binary>>) do
    case walk(rest, %{stop: :frame, orientation: 1, frame: nil}) do
      {:frame, %{frame: %{width: w, height: h}} = st} when w > 0 and h > 0 ->
        {w, h} = oriented(w, h, st.orientation)
        {:ok, %{width: w, height: h}}

      _ ->
        :error
    end
  end

  def info(_jpeg), do: :error

  @doc """
  Decodes at 1/8 scale and fits the result inside `max_width` x
  `max_height` (box-downscaling further when still too large; a 1/8 image
  already inside the box is returned as is). Encodes an RGB PNG.
  """
  @spec thumbnail(binary(), pos_integer(), pos_integer()) ::
          {:ok, %{data: binary(), mime: String.t(), width: pos_integer(), height: pos_integer()}}
          | :unsupported
          | {:error, term()}
  def thumbnail(<<0xFF, 0xD8, rest::binary>>, max_width, max_height) do
    st = %{stop: :scan, orientation: 1, frame: nil, dqt: %{}, dht: %{}, dri: 0}

    case walk(rest, st) do
      {:scan, scan, data, st} -> decode(st, scan, data, max_width, max_height)
      {:frame, _st} -> :unsupported
      {:error, reason} -> {:error, reason}
    end
  catch
    {:image_error, reason} -> {:error, reason}
  end

  def thumbnail(_jpeg, _max_width, _max_height), do: {:error, :not_jpeg}

  # -- markers --------------------------------------------------------------

  defp walk(<<0xFF, 0xFF, _::binary>> = bin, st),
    do: walk(binary_part(bin, 1, byte_size(bin) - 1), st)

  defp walk(<<0xFF, m, rest::binary>>, st) when m in 0xD0..0xD7 or m == 0x01, do: walk(rest, st)
  defp walk(<<0xFF, 0xD9, _::binary>>, _st), do: {:error, :no_scan}

  defp walk(<<0xFF, m, len::16, rest::binary>>, st) when len >= 2 do
    size = len - 2

    case rest do
      <<payload::binary-size(^size), tail::binary>> -> segment(m, payload, tail, st)
      _ -> {:error, :truncated}
    end
  end

  defp walk(_bin, _st), do: {:error, :bad_marker}

  defp segment(m, payload, tail, st) when m in [0xC0, 0xC1] do
    st = %{st | frame: frame(payload, true)}
    if st.stop == :frame, do: {:frame, st}, else: walk(tail, st)
  end

  defp segment(m, payload, _tail, st) when m in 0xC2..0xCF and m not in [0xC4, 0xC8, 0xCC],
    do: {:frame, %{st | frame: frame(payload, false)}}

  defp segment(0xE1, <<"Exif", 0, 0, tiff::binary>>, tail, st),
    do: walk(tail, %{st | orientation: exif_orientation(tiff)})

  defp segment(0xC4, payload, tail, %{stop: :scan} = st),
    do: walk(tail, %{st | dht: huffman_tables(payload, st.dht)})

  defp segment(0xDB, payload, tail, %{stop: :scan} = st),
    do: walk(tail, %{st | dqt: quant_tables(payload, st.dqt)})

  defp segment(0xDD, <<ri::16, _::binary>>, tail, %{stop: :scan} = st),
    do: walk(tail, %{st | dri: ri})

  defp segment(0xDA, _payload, _tail, %{frame: nil}), do: {:error, :no_frame}
  defp segment(0xDA, payload, tail, st), do: {:scan, payload, tail, st}
  defp segment(_m, _payload, tail, st), do: walk(tail, st)

  defp frame(<<precision, h::16, w::16, n, comps::binary-size(n * 3), _::binary>>, baseline) do
    comps = for <<id, hs::4, vs::4, tq <- comps>>, do: %{id: id, h: hs, v: vs, tq: tq}
    %{width: w, height: h, comps: comps, baseline: baseline and precision == 8}
  end

  defp frame(_payload, _baseline), do: %{width: 0, height: 0, comps: [], baseline: false}

  defp quant_tables(<<0::4, tq::4, q0, _::binary-63, rest::binary>>, acc),
    do: quant_tables(rest, Map.put(acc, tq, q0))

  defp quant_tables(<<1::4, tq::4, q0::16, _::binary-126, rest::binary>>, acc),
    do: quant_tables(rest, Map.put(acc, tq, q0))

  defp quant_tables(_rest, acc), do: acc

  defp huffman_tables(<<class::4, id::4, counts::binary-16, rest::binary>>, acc) do
    counts = :binary.bin_to_list(counts)
    total = Enum.sum(counts)
    <<symbols::binary-size(^total), rest::binary>> = rest
    huffman_tables(rest, Map.put(acc, {class, id}, huffman(counts, symbols)))
  end

  defp huffman_tables(_rest, acc), do: acc

  # {fast, maxcode, mincode, valptr, symbols}: `fast` maps every 9-bit
  # prefix to {length, symbol} for codes of at most 9 bits.
  defp huffman(counts, symbols) do
    {codes, maxcode, mincode, valptr} = canonical(counts)
    syms = :binary.bin_to_list(symbols)

    fast =
      codes
      |> Enum.zip(syms)
      |> Enum.filter(fn {{len, _code}, _sym} -> len <= 9 end)
      |> Enum.flat_map(fn {{len, code}, sym} ->
        first = code <<< (9 - len)
        for i <- first..(first + (1 <<< (9 - len)) - 1), do: {i, {len, sym}}
      end)
      |> Map.new()

    {List.to_tuple(for i <- 0..511, do: Map.get(fast, i)), maxcode, mincode, valptr,
     List.to_tuple(syms)}
  end

  defp canonical(counts) do
    {codes, _code, _k, maxcode, mincode, valptr} =
      counts
      |> Enum.with_index(1)
      |> Enum.reduce({[], 0, 0, [], [], []}, fn {count, len},
                                                {codes, code, k, maxc, minc, vptr} ->
        new = for i <- 0..(count - 1)//1, do: {len, code + i}
        max = if count > 0, do: code + count - 1, else: -1
        {[codes | new], (code + count) <<< 1, k + count, [max | maxc], [code | minc], [k | vptr]}
      end)

    tuple = &List.to_tuple([0 | Enum.reverse(&1)])
    {List.flatten(codes), tuple.(maxcode), tuple.(mincode), tuple.(valptr)}
  end

  # -- EXIF -----------------------------------------------------------------

  defp exif_orientation(<<"II", 42::little-16, offset::little-32, _::binary>> = tiff),
    do: ifd(tiff, offset, :little)

  defp exif_orientation(<<"MM", 42::16, offset::32, _::binary>> = tiff),
    do: ifd(tiff, offset, :big)

  defp exif_orientation(_tiff), do: 1

  defp ifd(tiff, offset, :little) do
    case tiff do
      <<_::binary-size(^offset), n::little-16, entries::binary>> -> entry(entries, n, :little)
      _ -> 1
    end
  end

  defp ifd(tiff, offset, :big) do
    case tiff do
      <<_::binary-size(^offset), n::16, entries::binary>> -> entry(entries, n, :big)
      _ -> 1
    end
  end

  defp entry(_entries, 0, _endian), do: 1

  defp entry(
         <<0x0112::little-16, 3::little-16, _::32, v::little-16, _::16, _::binary>>,
         _n,
         :little
       )
       when v in 1..8,
       do: v

  defp entry(<<0x0112::16, 3::16, _::32, v::16, _::16, _::binary>>, _n, :big) when v in 1..8,
    do: v

  defp entry(<<_::binary-12, rest::binary>>, n, endian), do: entry(rest, n - 1, endian)
  defp entry(_entries, _n, _endian), do: 1

  defp oriented(w, h, o) when o >= 5, do: {h, w}
  defp oriented(w, h, _o), do: {w, h}

  # -- scan setup -----------------------------------------------------------

  defp decode(%{frame: %{baseline: false}}, _scan, _data, _mw, _mh), do: :unsupported

  defp decode(%{frame: frame} = st, <<n, sel::binary-size(n * 2), _::binary>>, data, mw, mh) do
    scan = for <<id, td::4, ta::4 <- sel>>, do: {id, td, ta}

    if frame.width > 0 and frame.height > 0 and length(frame.comps) in [1, 3] and
         length(scan) == length(frame.comps) do
      run(st, components(frame, scan, st), data, mw, mh)
    else
      :unsupported
    end
  end

  defp decode(_st, _scan, _data, _mw, _mh), do: {:error, :bad_scan}

  # Scan-ordered components with their tables; a single-component scan is
  # non-interleaved (one block per MCU).
  defp components(%{comps: [_one]} = frame, [{_id, td, ta}], st) do
    [
      %{
        h: 1,
        v: 1,
        dct: dht(st, 0, td),
        act: dht(st, 1, ta),
        q: dqt(st, hd(frame.comps).tq)
      }
    ]
  end

  defp components(frame, scan, st) do
    by_id = Map.new(frame.comps, &{&1.id, &1})

    for {id, td, ta} <- scan do
      c = Map.get(by_id, id) || throw({:image_error, :bad_scan})

      %{
        h: c.h,
        v: c.v,
        dct: dht(st, 0, td),
        act: dht(st, 1, ta),
        q: dqt(st, c.tq)
      }
    end
  end

  defp dht(st, class, id),
    do: Map.get(st.dht, {class, id}) || throw({:image_error, :missing_huffman})

  defp dqt(st, id), do: Map.get(st.dqt, id) || throw({:image_error, :missing_quant})

  defp run(%{frame: frame} = st, comps, data, mw, mh) do
    hmax = comps |> Enum.map(& &1.h) |> Enum.max()
    vmax = comps |> Enum.map(& &1.v) |> Enum.max()

    if Enum.any?(comps, &(&1.h == 0 or &1.v == 0)), do: throw({:image_error, :bad_sampling})

    ow = div(frame.width + 7, 8)
    oh = div(frame.height + 7, 8)
    {dw, dh} = oriented(ow, oh, st.orientation)
    {tw, th} = Resample.fit(dw, dh, mw, mh)
    {sw, sh} = oriented(tw, th, st.orientation)
    channels = if match?([_], comps), do: 1, else: 3

    geo = %{
      ow: ow,
      oh: oh,
      hmax: hmax,
      vmax: vmax,
      mcux: div(frame.width + 8 * hmax - 1, 8 * hmax),
      mcuy: div(frame.height + 8 * vmax - 1, 8 * vmax),
      dri: st.dri,
      cols: Resample.spans(ow, sw),
      channels: channels
    }

    writer = PngWriter.new(tw, th, 3)

    try do
      sink = if st.orientation == 1, do: {&PngWriter.row/2, writer}, else: {&[&1 | &2], []}
      rs = Resample.new(geo.cols, Resample.spans(oh, sh), channels)
      {_rs, {_fun, out}} = mcu_rows(data, comps, geo, rs, sink)

      writer =
        if st.orientation == 1,
          do: out,
          else: reorient(out, sw, sh, st.orientation) |> Enum.reduce(writer, &PngWriter.row/2)

      {:ok, %{data: PngWriter.finish(writer), mime: "image/png", width: tw, height: th}}
    after
      PngWriter.close(writer)
    end
  end

  # -- entropy decoding -----------------------------------------------------

  defp mcu_rows(data, comps, geo, rs, sink) do
    preds = Enum.map(comps, fn _ -> 0 end)
    state = {data, 0, 0, preds, 0}

    {_state, rs, sink} =
      Enum.reduce(0..(geo.mcuy - 1)//1, {state, rs, sink}, fn my, {state, rs, sink} ->
        {state, mcus} = mcu_row(state, comps, geo, geo.mcux, [])
        rows = min(geo.vmax, geo.oh - my * geo.vmax)

        emit_rows(mcus, comps, geo, rows, rs, sink)
        |> then(fn {rs, sink} -> {state, rs, sink} end)
      end)

    {rs, sink}
  end

  defp mcu_row(state, _comps, _geo, 0, mcus), do: {state, Enum.reverse(mcus)}

  defp mcu_row({bin, acc, n, preds, count}, comps, geo, left, mcus) do
    {vals, preds, bin, acc, n} = mcu(comps, preds, bin, acc, n, [], [])
    count = count + 1
    state = restart({bin, acc, n, preds, count}, geo)
    mcu_row(state, comps, geo, left - 1, [vals | mcus])
  end

  defp restart({bin, _acc, _n, preds, count}, %{dri: ri}) when ri > 0 and rem(count, ri) == 0,
    do: {skip_rst(bin), 0, 0, Enum.map(preds, fn _ -> 0 end), count}

  defp restart(state, _geo), do: state

  defp skip_rst(<<0xFF, 0xFF, _::binary>> = bin),
    do: skip_rst(binary_part(bin, 1, byte_size(bin) - 1))

  defp skip_rst(<<0xFF, m, rest::binary>>) when m in 0xD0..0xD7, do: rest
  defp skip_rst(bin), do: bin

  defp mcu([], [], bin, acc, n, vals, preds),
    do: {Enum.reverse(vals), Enum.reverse(preds), bin, acc, n}

  defp mcu([c | cs], [p | ps], bin, acc, n, vals, preds) do
    {bvals, p, bin, acc, n} = blocks(c.h * c.v, c, p, bin, acc, n, [])
    mcu(cs, ps, bin, acc, n, [bvals | vals], [p | preds])
  end

  defp blocks(0, _c, p, bin, acc, n, out), do: {Enum.reverse(out), p, bin, acc, n}

  defp blocks(k, c, p, bin, acc, n, out) do
    {diff, bin, acc, n} = block(bin, acc, n, c.dct, c.act)
    p = p + diff
    blocks(k - 1, c, p, bin, acc, n, [dc_pixel(p * c.q) | out])
  end

  defp dc_pixel(dc) do
    v = 128 + Integer.floor_div(dc + 4, 8)

    cond do
      v < 0 -> 0
      v > 255 -> 255
      true -> v
    end
  end

  defp block(bin, acc, n, dct, act) do
    {bin, acc, n} = fill(bin, acc, n)
    {s, n} = symbol(acc, n, dct)
    {diff, n} = extend(acc, n, s)
    {bin, acc, n} = skip_ac(bin, acc, n, act, 1)
    {diff, bin, acc, n}
  end

  defp skip_ac(bin, acc, n, _act, k) when k > 63, do: {bin, acc, n}

  defp skip_ac(bin, acc, n, act, k) do
    {bin, acc, n} = fill(bin, acc, n)

    case symbol(acc, n, act) do
      {0x00, n} -> {bin, acc, n}
      {0xF0, n} -> skip_ac(bin, acc, n, act, k + 16)
      {rs, n} -> skip_ac(bin, acc, n - (rs &&& 15), act, k + (rs >>> 4) + 1)
    end
  end

  defp extend(_acc, n, 0), do: {0, n}

  defp extend(acc, n, s) do
    n = n - s
    v = acc >>> n &&& (1 <<< s) - 1
    if v < 1 <<< (s - 1), do: {v - (1 <<< s) + 1, n}, else: {v, n}
  end

  defp symbol(acc, n, {fast, _maxcode, _mincode, _valptr, _syms} = table) do
    case elem(fast, acc >>> (n - 9) &&& 511) do
      {len, sym} -> {sym, n - len}
      nil -> slow_symbol(acc, n, 10, table)
    end
  end

  defp slow_symbol(_acc, _n, 17, _table), do: throw({:image_error, :bad_huffman_code})

  defp slow_symbol(acc, n, len, {_fast, maxcode, mincode, valptr, syms} = table) do
    code = acc >>> (n - len) &&& (1 <<< len) - 1

    if code <= elem(maxcode, len),
      do: {elem(syms, elem(valptr, len) + code - elem(mincode, len)), n - len},
      else: slow_symbol(acc, n, len + 1, table)
  end

  # Keeps at least 32 bits buffered; at a marker or the end, pads with zeros.
  defp fill(bin, acc, n) when n >= 32, do: {bin, acc, n}
  defp fill(<<0xFF, 0x00, rest::binary>>, acc, n), do: fill(rest, push8(acc, n, 0xFF), n + 8)
  defp fill(<<0xFF, _marker, _::binary>> = bin, acc, n), do: fill_zeros(bin, acc, n)
  defp fill(<<b, rest::binary>>, acc, n), do: fill(rest, push8(acc, n, b), n + 8)
  defp fill(<<>>, acc, n), do: fill_zeros(<<>>, acc, n)

  defp fill_zeros(bin, acc, n) when n >= 32, do: {bin, acc, n}
  defp fill_zeros(bin, acc, n), do: fill_zeros(bin, push8(acc, n, 0), n + 8)

  defp push8(acc, n, b), do: (acc &&& (1 <<< n) - 1) <<< 8 ||| b

  # -- 1/8 rows -------------------------------------------------------------

  defp emit_rows(mcus, comps, geo, rows, rs, sink) do
    planes =
      comps
      |> Enum.with_index()
      |> Enum.map(fn {c, i} -> plane(mcus, i, c) end)

    Enum.reduce(0..(rows - 1)//1, {rs, sink}, fn oy, {rs, sink} ->
      row = pixel_row(planes, comps, geo, oy)

      case Resample.push(rs, row) do
        {:cont, rs} ->
          {rs, sink}

        {:emit, _r, sums, count, rs} ->
          {rs, push_sink(sink, Resample.finalize(sums, geo.cols, count, geo.channels))}
      end
    end)
  end

  defp push_sink({fun, acc}, row), do: {fun, fun.(row, acc)}

  # A component's block rows for one MCU row, as tuples of pixel values.
  defp plane(mcus, i, c) do
    for v <- 0..(c.v - 1) do
      mcus
      |> Enum.flat_map(fn vals -> vals |> Enum.at(i) |> Enum.slice(v * c.h, c.h) end)
      |> List.to_tuple()
    end
    |> List.to_tuple()
  end

  defp pixel_row([y], _comps, geo, _oy) do
    y |> elem(0) |> Tuple.to_list() |> Enum.take(geo.ow) |> :erlang.list_to_binary()
  end

  defp pixel_row([y, cb, cr], [yc, cbc, crc], geo, oy) do
    ty = elem(y, div(oy * yc.v, geo.vmax))
    tcb = elem(cb, div(oy * cbc.v, geo.vmax))
    tcr = elem(cr, div(oy * crc.v, geo.vmax))
    {hy, hcb, hcr, hmax} = {yc.h, cbc.h, crc.h, geo.hmax}

    for ox <- 0..(geo.ow - 1), into: <<>> do
      ycc(
        elem(ty, div(ox * hy, hmax)),
        elem(tcb, div(ox * hcb, hmax)),
        elem(tcr, div(ox * hcr, hmax))
      )
    end
  end

  defp ycc(y, cb, cr) do
    cb = cb - 128
    cr = cr - 128
    r = y + ((91_881 * cr + 32_768) >>> 16)
    g = y + ((-22_554 * cb - 46_802 * cr + 32_768) >>> 16)
    b = y + ((116_130 * cb + 32_768) >>> 16)
    <<clamp(r), clamp(g), clamp(b)>>
  end

  defp clamp(v) when v < 0, do: 0
  defp clamp(v) when v > 255, do: 255
  defp clamp(v), do: v

  # -- orientation ----------------------------------------------------------

  # `rows` (reversed) hold the stored-orientation image, sw x sh RGB.
  defp reorient(rows, sw, sh, o) do
    img = rows |> Enum.reverse() |> IO.iodata_to_binary()
    {dw, dh} = oriented(sw, sh, o)

    for y <- 0..(dh - 1) do
      for x <- 0..(dw - 1), into: <<>> do
        {sx, sy} = source(o, x, y, sw, sh)
        binary_part(img, (sy * sw + sx) * 3, 3)
      end
    end
  end

  defp source(2, x, y, sw, _sh), do: {sw - 1 - x, y}
  defp source(3, x, y, sw, sh), do: {sw - 1 - x, sh - 1 - y}
  defp source(4, x, y, _sw, sh), do: {x, sh - 1 - y}
  defp source(5, x, y, _sw, _sh), do: {y, x}
  defp source(6, x, y, _sw, sh), do: {y, sh - 1 - x}
  defp source(7, x, y, sw, sh), do: {sw - 1 - y, sh - 1 - x}
  defp source(8, x, y, sw, _sh), do: {sw - 1 - y, x}
end
