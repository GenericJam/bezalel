defmodule Bezalel.Images.Resample do
  @moduledoc """
  Streaming area-average (box filter) downscaler.

  Source rows arrive one at a time as 8-bit binaries with 1 (gray),
  2 (gray + alpha), 3 (RGB) or 4 (RGBA) channels. Every destination pixel
  covers a rectangle of source pixels (`spans/2` partitions the source
  columns and rows); a destination pixel is the plain average of the source
  pixels it covers. Only the running column sums of the destination row
  being built are kept, so memory is one source row plus one destination
  row of integers.

  Channels with alpha are averaged alpha-weighted (premultiplied): a fully
  transparent pixel contributes nothing to the colour, only to the alpha.

  `lattice_spans/5` handles sources that only hold every `step`-th pixel
  (the passes of an Adam7-interlaced PNG); spans can then be zero.
  """

  defstruct [:channels, :cols, :rows, :r, :left, :count, :acc]

  @type t :: %__MODULE__{}

  @doc """
  Fits `width` x `height` inside `max_width` x `max_height`, keeping the
  aspect ratio and never upscaling.
  """
  @spec fit(pos_integer(), pos_integer(), pos_integer(), pos_integer()) ::
          {pos_integer(), pos_integer()}
  def fit(width, height, max_width, max_height)
      when width <= max_width and height <= max_height,
      do: {width, height}

  def fit(width, height, max_width, max_height) when width * max_height >= height * max_width do
    {max_width, clamp(div(2 * height * max_width + width, 2 * width), max_height)}
  end

  def fit(width, height, max_width, max_height) do
    {clamp(div(2 * width * max_height + height, 2 * height), max_width), max_height}
  end

  defp clamp(v, max), do: v |> max(1) |> min(max)

  @doc "How many of `src` source pixels each of `dst` destination pixels covers."
  @spec spans(pos_integer(), pos_integer()) :: [pos_integer()]
  def spans(src, dst), do: lattice_spans(src, dst, 0, 1, src)

  @doc """
  Like `spans/2`, for a source that only holds the `n` pixels at
  `origin + k * step` of a `src`-wide line.
  """
  @spec lattice_spans(
          pos_integer(),
          pos_integer(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer()
        ) ::
          [non_neg_integer()]
  def lattice_spans(src, dst, origin, step, n) do
    for i <- 0..(dst - 1)//1 do
      below(div((i + 1) * src, dst), origin, step, n) - below(div(i * src, dst), origin, step, n)
    end
  end

  defp below(x, origin, _step, _n) when x <= origin, do: 0
  defp below(x, origin, step, n), do: min(div(x - origin + step - 1, step), n)

  @doc "A resampler for rows split by `cols` spans, grouped by `rows` spans."
  @spec new([non_neg_integer()], [non_neg_integer()], 1..4) :: t()
  def new(cols, rows, channels) do
    advance(%__MODULE__{channels: channels, cols: cols, rows: rows, r: -1})
  end

  defp advance(%{rows: [0 | rest]} = s), do: advance(%{s | rows: rest, r: s.r + 1})

  defp advance(%{rows: [n | rest]} = s),
    do: %{s | rows: rest, r: s.r + 1, left: n, count: n, acc: nil}

  defp advance(%{rows: []} = s), do: %{s | left: 0, acc: nil}

  @doc """
  Adds one source row. Returns `{:emit, dest_row_index, sums, row_count, s}`
  when it completes a destination row (`sums` are raw per-column channel
  sums for `finalize/4`), else `{:cont, s}`.
  """
  @spec push(t(), binary()) ::
          {:cont, t()} | {:emit, non_neg_integer(), [non_neg_integer()], pos_integer(), t()}
  def push(%{left: 0}, _row), do: throw({:image_error, :too_many_rows})

  def push(%{acc: acc, cols: cols, channels: c} = s, row) do
    sums = hsum(row, cols, c)
    acc = if acc, do: vadd(acc, sums), else: sums

    case s.left do
      1 -> {:emit, s.r, acc, s.count, advance(s)}
      left -> {:cont, %{s | acc: acc, left: left - 1}}
    end
  end

  @doc """
  Turns raw sums into an 8-bit RGB (1/3 channels) or RGBA (2/4 channels)
  row. `cols` are the full-image column spans, `row_count` how many source
  rows were summed.
  """
  @spec finalize([non_neg_integer()], [pos_integer()], pos_integer(), 1..4) :: binary()
  def finalize(sums, cols, row_count, 1), do: f1(sums, cols, row_count, <<>>)
  def finalize(sums, cols, row_count, 2), do: f2(sums, cols, row_count, <<>>)
  def finalize(sums, cols, row_count, 3), do: f3(sums, cols, row_count, <<>>)
  def finalize(sums, cols, row_count, 4), do: f4(sums, cols, row_count, <<>>)

  @doc "Output channels (3 or 4) for a native channel count."
  @spec out_channels(1..4) :: 3 | 4
  def out_channels(c) when c in [2, 4], do: 4
  def out_channels(_c), do: 3

  @doc "The largest raw sum a destination pixel can reach."
  @spec max_sum([pos_integer()], [pos_integer()], 1..4) :: pos_integer()
  def max_sum(cols, rows, c) do
    per = if c in [2, 4], do: 255 * 255, else: 255
    per * Enum.max(cols) * Enum.max(rows)
  end

  # -- horizontal sums ------------------------------------------------------

  defp hsum(row, cols, 1), do: h1(row, cols)
  defp hsum(row, cols, 2), do: h2(row, cols)
  defp hsum(row, cols, 3), do: h3(row, cols)
  defp hsum(row, cols, 4), do: h4(row, cols)

  defp h1(_row, []), do: []

  defp h1(row, [n | ns]) do
    {v, rest} = s1(row, n, 0)
    [v | h1(rest, ns)]
  end

  defp s1(row, 0, v), do: {v, row}
  defp s1(<<x, rest::binary>>, n, v), do: s1(rest, n - 1, v + x)

  defp h2(_row, []), do: []

  defp h2(row, [n | ns]) do
    {g, a, rest} = s2(row, n, 0, 0)
    [g, a | h2(rest, ns)]
  end

  defp s2(row, 0, g, a), do: {g, a, row}
  defp s2(<<x, y, rest::binary>>, n, g, a), do: s2(rest, n - 1, g + x * y, a + y)

  defp h3(_row, []), do: []

  defp h3(row, [n | ns]) do
    {r, g, b, rest} = s3(row, n, 0, 0, 0)
    [r, g, b | h3(rest, ns)]
  end

  defp s3(row, 0, r, g, b), do: {r, g, b, row}
  defp s3(<<x, y, z, rest::binary>>, n, r, g, b), do: s3(rest, n - 1, r + x, g + y, b + z)

  defp h4(_row, []), do: []

  defp h4(row, [n | ns]) do
    {r, g, b, a, rest} = s4(row, n, 0, 0, 0, 0)
    [r, g, b, a | h4(rest, ns)]
  end

  defp s4(row, 0, r, g, b, a), do: {r, g, b, a, row}

  defp s4(<<x, y, z, w, rest::binary>>, n, r, g, b, a),
    do: s4(rest, n - 1, r + x * w, g + y * w, b + z * w, a + w)

  defp vadd([a | as], [b | bs]), do: [a + b | vadd(as, bs)]
  defp vadd([], []), do: []

  # -- finalize -------------------------------------------------------------

  defp f1([v | vs], [n | ns], rc, acc) do
    v = avg(v, n * rc)
    f1(vs, ns, rc, <<acc::binary, v, v, v>>)
  end

  defp f1([], [], _rc, acc), do: acc

  defp f2([g, a | vs], [n | ns], rc, acc) do
    g = unpremultiply(g, a)
    f2(vs, ns, rc, <<acc::binary, g, g, g, avg(a, n * rc)>>)
  end

  defp f2([], [], _rc, acc), do: acc

  defp f3([r, g, b | vs], [n | ns], rc, acc) do
    area = n * rc
    f3(vs, ns, rc, <<acc::binary, avg(r, area), avg(g, area), avg(b, area)>>)
  end

  defp f3([], [], _rc, acc), do: acc

  defp f4([r, g, b, a | vs], [n | ns], rc, acc) do
    px = <<unpremultiply(r, a), unpremultiply(g, a), unpremultiply(b, a), avg(a, n * rc)>>
    f4(vs, ns, rc, <<acc::binary, px::binary>>)
  end

  defp f4([], [], _rc, acc), do: acc

  defp avg(sum, area), do: div(sum + div(area, 2), area)

  defp unpremultiply(_sum, 0), do: 0
  defp unpremultiply(sum, alpha), do: div(sum + div(alpha, 2), alpha)
end
