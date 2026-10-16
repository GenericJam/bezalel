defmodule Bezalel.Workshop do
  @moduledoc """
  The Workshop: builds study tools from a description
  (decisions/2026-10-15-workshop-on-dyn.md).

  **With a model** (a sign-in or API key, `Bezalel.Agent.live?/1`) and the
  Dyn layer running (`available/0`), a build is real code: the model
  writes a tool (a `Rho.Tool` over the study library,
  `Bezalel.Workshop.Study`) and usually its screen, in rho's Dyn layer
  (`Bezalel.Workshop.Builder`), and proposes it as a new generation:
  checked, compiled and selftested, nothing running yet. The user sees
  what it adds (`review/2`) and approves it (`approve/1`, after the
  approval sheet) or discards it. An approved generation runs on
  probation: three crashes within a minute, or a launch that dies, revert
  it (`Rho.Dyn.Keeper`), and the Workshop says so (`status/1`). A built
  tool is offered to the study agent from its next model call
  (`Rho.Dyn.Source`), and its screen opens in its panel
  (`Bezalel.Workshop.Host`). "Change the tool" builds again with the tool
  named (a new generation over the current one); Remove proposes a
  generation without it.

  The shelf (`Bezalel.Library.Tool`, kind `"dyn"`) names the tool's module,
  tool, screen and files, and keeps one version per approved change (the
  request, the model, the build session and the generation it made, or a
  removal). The row shows the version in the generation that runs, so it
  follows the Keeper's reverts (`reconcile/0`); the code lives in the
  generations (`Rho.Dyn.Store`, under rho's data dir).

  **Without a model**, a build is the design's storyboard
  (`Bezalel.Workshop.Storyboard`): the sample sermon outline for Exodus
  31, whatever is described, and the Workshop says so.
  """

  alias Bezalel.Library
  alias Bezalel.Library.Tool
  alias Bezalel.Workshop.{Builder, Prompt, Storyboard}
  alias Rho.Dyn
  alias Rho.Dyn.Approval.Biometric

  @sample_steps [
    "Reading your request",
    "Laying out the sections",
    "Linking it to Exodus 31",
    "Saving it to your phone"
  ]

  @live_steps [
    "Reading your request",
    "Writing the tool",
    "Checking and testing it",
    "Ready for your approval"
  ]

  @ns "Bezalel.Dyn."

  @typedoc "A tool a proposal adds, changes or removes."
  @type change :: %{
          module: String.t(),
          title: String.t(),
          tool: String.t(),
          screen: String.t() | nil,
          files: [String.t()],
          change: :new | :changed | :removed
        }

  @typedoc """
  A proposed generation as the Workshop shows it before approval: the
  generation `n`, the model's `rationale` and closing `summary`, the
  tools it adds, changes or removes, the selftests, the diff, and what
  the shelf records once it's approved.
  """
  @type review :: %{
          n: pos_integer(),
          rationale: String.t(),
          summary: String.t(),
          changes: [change()],
          selftests: [map()],
          diff: String.t(),
          description: String.t(),
          conversation_id: integer() | nil,
          model: String.t() | nil,
          session: String.t() | nil
        }

  @doc "The build steps, in order: a live build's, or the storyboard's."
  @spec steps(boolean()) :: [String.t()]
  def steps(true), do: @live_steps
  def steps(false), do: @sample_steps

  @doc """
  How a build runs for `account` (`Bezalel.Account.status/0`): `:live`
  (a model writes the tool), `:sample` (no model: the storyboard), or
  `{:unavailable, why}` (a model, but no Dyn layer to build in: the
  storyboard, and the Workshop says why).
  """
  @spec mode(map()) :: :live | :sample | {:unavailable, String.t()}
  def mode(account) do
    cond do
      not Bezalel.Agent.live?(account) -> :sample
      reason = unavailable() -> {:unavailable, reason}
      true -> :live
    end
  end

  @doc "Whether the Dyn layer can take a new tool now: nil, or why not."
  @spec unavailable() :: String.t() | nil
  def unavailable do
    status = Dyn.status()

    cond do
      status.mode == :off ->
        "Building tools isn't switched on in this build of Bezalel."

      not compiler?() ->
        "This build of Bezalel can't compile code on the phone (its Elixir compiler was left out)."

      status.mode == :safe ->
        "Bezalel started without your tools after two launches failed, so it can't add one " <>
          "until it restarts normally."

      true ->
        nil
    end
  end

  @doc """
  Whether this runtime can compile Elixir: the Erlang compiler and
  Elixir's own compiler modules are loadable. A slim release that strips
  `:compiler` (mob_dev's `--slim` baseline lists it) can't build tools.
  """
  @spec compiler?() :: boolean()
  def compiler? do
    Enum.all?(
      [:compile, :elixir_compiler, :elixir_erl, Kernel.ErrorHandler],
      &Code.ensure_loaded?/1
    )
  end

  @doc """
  Builds from `description`. Options: `:mode` (`mode/1`), `:conversation_id`
  (the conversation it came from), `:model_id`, `:on_step` (called with
  each step's index as it starts), `:tool` (a `"dyn"` tool to change).

  The storyboard saves its sample and returns `{:ok, %Tool{}}`; a live
  build returns `{:ok, {:review, review}}`, the proposal waiting for
  approval, or `{:error, message}`.
  """
  @spec build(String.t(), keyword()) ::
          {:ok, Tool.t()} | {:ok, {:review, review()}} | {:error, String.t()}
  def build(description, opts) do
    on_step = Keyword.get(opts, :on_step, fn _ -> :ok end)
    model_id = Keyword.get(opts, :model_id)
    conversation_id = Keyword.get(opts, :conversation_id)

    case Keyword.get(opts, :mode, :sample) do
      :live ->
        tool = Keyword.get(opts, :tool)
        request = Prompt.request(description, tool && tool.data)

        with {:ok, built} <- Builder.build(request, model_id, on_step) do
          review(built.n, %{
            summary: built.summary,
            session: built.session,
            description: description,
            conversation_id: conversation_id,
            model: model_id
          })
        end

      _sample ->
        sample(description, conversation_id, model_id, on_step)
    end
  end

  defp sample(description, conversation_id, model_id, on_step) do
    {:ok, spec} = Storyboard.build(description, Bezalel.Models.get(model_id), on_step)
    on_step.(length(@sample_steps) - 1)
    {by, spec} = Map.pop(spec, :by)

    attrs =
      Map.merge(spec, %{description: description, conversation_id: conversation_id, model: by})

    case Library.create_tool(attrs) do
      {:ok, tool} -> {:ok, tool}
      {:error, _changeset} -> {:error, "The tool couldn't be saved."}
    end
  end

  @doc """
  The pending generation `n` as the user reviews it, with `extra` (the
  review's `summary`, `session`, `description`, `conversation_id`,
  `model`).
  """
  @spec review(pos_integer(), map()) :: {:ok, {:review, review()}} | {:error, String.t()}
  def review(n, extra) do
    with {:ok, gen} <- Dyn.generation(n),
         {:ok, parent} <- Dyn.generation(gen.parent || 0) do
      new_sources = Dyn.sources(n)
      old_sources = Dyn.sources(parent.n)

      review =
        Map.merge(
          %{
            summary: "",
            session: nil,
            description: gen.rationale,
            conversation_id: nil,
            model: nil
          },
          extra
        )
        |> Map.merge(%{
          n: n,
          rationale: gen.rationale,
          changes: changes(gen, new_sources, parent, old_sources),
          selftests: gen.selftests,
          diff: Dyn.diff(n)
        })

      {:ok, {:review, review}}
    else
      _ -> {:error, "The proposal couldn't be read back."}
    end
  end

  # The tools of `gen` that are new, or whose files changed, and those of
  # `parent` it no longer has; each with its screen (`<Name>.Screen`).
  defp changes(gen, new_sources, parent, old_sources) do
    new = tools(gen, new_sources)
    old = tools(parent, old_sources)
    old_by_module = Map.new(old, &{&1.module, &1})
    new_modules = MapSet.new(new, & &1.module)

    kept =
      for t <- new,
          change = change(t, old_by_module[t.module], new_sources, old_sources),
          change != nil,
          do: Map.put(t, :change, change)

    removed =
      for t <- old,
          not MapSet.member?(new_modules, t.module),
          do: Map.put(t, :change, :removed)

    kept ++ removed
  end

  defp change(_tool, nil, _new_sources, _old_sources), do: :new

  defp change(tool, _old, new_sources, old_sources) do
    if Enum.any?(tool.files, &(new_sources[&1] != old_sources[&1])), do: :changed
  end

  defp tools(gen, sources) do
    screens = for %{kind: :screen, name: name} <- gen.modules, into: MapSet.new(), do: name

    for %{kind: :tool, module: module, name: name} <- gen.modules do
      short = String.replace_prefix(module, @ns, "")
      screen = if MapSet.member?(screens, short <> ".Screen"), do: short <> ".Screen"
      modules = [module | if(screen, do: [@ns <> screen], else: [])]

      %{
        module: module,
        title: title(short),
        tool: name,
        screen: screen,
        files: files(sources, modules)
      }
    end
  end

  # The sources defining any of `modules` (`defmodule X do` or `defmodule X, do:`).
  defp files(sources, modules) do
    for {path, source} <- Enum.sort(sources),
        Enum.any?(modules, &defines?(source, &1)),
        do: path
  end

  defp defines?(source, module),
    do: String.contains?(source, ["defmodule #{module} do", "defmodule #{module},"])

  @doc ~S|What the user sees a module called: `"WordFrequency"` is "Word Frequency".|
  @spec title(String.t()) :: String.t()
  def title(short) do
    [first | rest] = short |> String.split(".") |> hd() |> String.graphemes()

    {letters, _} =
      Enum.map_reduce(rest, first, fn g, prev ->
        if upper?(g) and not upper?(prev), do: {" " <> g, g}, else: {g, g}
      end)

    Enum.join([first | letters])
  end

  defp upper?(g), do: g != String.downcase(g)

  @doc """
  Activates the reviewed generation: the user just approved it on the
  approval sheet (`Rho.Dyn.Approval.Biometric.confirm/1`, then a token
  for exactly this generation). It goes on probation, and the shelf
  follows: a new tool is added, a changed one gets a version for the
  generation, a removed one gets a removal (and leaves the shelf until a
  revert brings it back). Returns the tools added or changed.
  """
  @spec approve(review()) :: {:ok, [Tool.t()]} | {:error, String.t()}
  def approve(%{n: n} = review) do
    subject = {:activate, n}
    :ok = Biometric.confirm(subject)

    with {:ok, token} <- Dyn.request_approval(subject),
         {:ok, _gen} <- Dyn.activate(n, token) do
      {:ok, shelve(review)}
    else
      {:error, reason} -> {:error, "It couldn't be added: #{describe(reason)}"}
    end
  end

  defp shelve(review) do
    rows = Library.list_tools(:all)

    for change <- review.changes,
        tool = shelve(change, by_module(rows, change.module), review),
        tool != nil,
        do: tool
  end

  defp shelve(%{change: :removed}, rows, review) do
    for row <- rows do
      version = %{"generation" => review.n, "removed" => true}
      {:ok, _} = Library.update_tool(row, %{data: show(row.data, version, %{})})
    end

    nil
  end

  defp shelve(change, rows, review) do
    version = %{
      "generation" => review.n,
      "description" => review.description,
      "model" => review.model,
      "session" => review.session
    }

    result =
      case rows do
        [] ->
          Library.create_tool(%{
            name: change.title,
            kind: "dyn",
            description: review.description,
            conversation_id: review.conversation_id,
            model: review.model,
            data: show(%{"module" => change.module}, version, change)
          })

        [row | _] ->
          model = review.model || row.model

          Library.update_tool(row, %{
            data: show(row.data, %{version | "model" => model}, change),
            description: review.description,
            model: model
          })
      end

    case result do
      {:ok, tool} -> tool
      {:error, _} -> nil
    end
  end

  # A row's data with `version` added and shown: its generation and
  # session, the tool's name, screen and files from `code` (a `tools/2`
  # entry, or `%{}` to keep them), and whether it is removed.
  defp show(data, version, code) do
    versions =
      data
      |> versions()
      |> Enum.reject(&(&1["generation"] == version["generation"]))
      |> Kernel.++([version])
      |> Enum.sort_by(& &1["generation"])

    data
    |> Map.merge(%{
      "versions" => versions,
      "removed" => version["removed"] == true
    })
    |> shown(version, code)
  end

  defp shown(data, %{"removed" => true}, _code), do: data

  defp shown(data, version, code) do
    data
    |> Map.merge(%{"generation" => version["generation"], "session" => version["session"]})
    |> Map.merge(Map.new(Map.take(code, [:tool, :screen, :files]), fn {k, v} -> {"#{k}", v} end))
  end

  defp versions(data), do: Map.get(data, "versions", [])

  defp by_module(rows, module),
    do: Enum.filter(rows, &(&1.kind == "dyn" and &1.data["module"] == module))

  @doc """
  Puts the shelf in line with the generation that runs (the Keeper's
  current one), after a revert (`Bezalel.Views.Workshop.dyn_event/2`)
  and at app start (a launch that died reverts at the next boot, with
  nobody listening). Each `"dyn"` row shows its version in that
  generation's line (the generation and its ancestors): its request,
  model, session and generation, and the tool's name, screen and files
  as that generation has them; a row whose version there is a removal
  leaves the shelf, and one a revert took a removal back from returns. A
  row with no version in the line (a new tool that was reverted) stays
  as it is, and `status/1` says why. A tool that runs with no row gets
  one, named after its module, with the request of the generation that
  added it.
  """
  @spec reconcile() :: :ok
  def reconcile do
    case Dyn.status() do
      %{mode: :off} -> :ok
      %{generation: current} -> reconcile(current)
    end
  end

  defp reconcile(current) do
    line = line(current)
    in_line = MapSet.new(line, & &1.n)
    running = Map.new(tools(hd(line), Dyn.sources(current)), &{&1.module, &1})
    rows = for row <- Library.list_tools(:all), row.kind == "dyn", do: row

    for row <- rows,
        version = row |> versions_of() |> Enum.filter(&(&1["generation"] in in_line)),
        version != [] do
      follow(row, List.last(version), Map.get(running, row.data["module"], %{}))
    end

    shelved = MapSet.new(rows, & &1.data["module"])

    for {module, code} <- running, not MapSet.member?(shelved, module) do
      added = line |> Enum.reverse() |> Enum.find(&has_tool?(&1, module))

      description =
        if added.rationale in [nil, ""], do: "Built in the Workshop", else: added.rationale

      version = %{"generation" => added.n, "description" => description}

      {:ok, _} =
        Library.create_tool(%{
          name: code.title,
          kind: "dyn",
          description: description,
          data: show(%{"module" => module}, version, code)
        })
    end

    :ok
  end

  defp versions_of(%Tool{data: data}), do: versions(data)

  defp follow(row, version, code) do
    data = row.data |> Map.put("removed", version["removed"] == true) |> shown(version, code)

    attrs =
      if version["removed"],
        do: %{data: data},
        else: %{
          data: data,
          description: version["description"] || row.description,
          model: version["model"]
        }

    if Enum.any?(attrs, fn {k, v} -> Map.get(row, k) != v end),
      do: {:ok, _} = Library.update_tool(row, attrs)
  end

  # The generation `n` and its ancestors, newest first, down to 0.
  defp line(n) do
    case Dyn.generation(n) do
      {:ok, %{parent: parent} = gen} when is_integer(parent) and parent < n ->
        [gen | line(parent)]

      {:ok, gen} ->
        [gen]

      {:error, _} ->
        [%Rho.Dyn.Generation{n: n}]
    end
  end

  defp has_tool?(gen, module),
    do: Enum.any?(gen.modules, &(&1.kind == :tool and &1.module == module))

  @doc "Drops the reviewed generation (nothing that runs changes)."
  @spec discard(review()) :: :ok
  def discard(%{n: n}) do
    _ = Dyn.discard(n)
    :ok
  end

  @doc """
  Removes a built tool. A Workshop tool in the generation that runs is
  removed by a new generation without its files, which the user approves
  like any other (`{:ok, {:review, review}}`); a sample, or a tool whose
  code isn't in it (reverted), just leaves the shelf (`{:ok, :removed}`).
  In safe mode or while its generation is rebuilt nothing is removed.
  """
  @spec remove(Tool.t()) :: {:ok, :removed} | {:ok, {:review, review()}} | {:error, String.t()}
  def remove(%Tool{kind: "dyn", name: name, data: data} = tool) do
    dyn = Dyn.status()

    cond do
      dyn.mode == :safe ->
        {:error, "#{name} can't be removed until Bezalel starts normally with your tools."}

      Dyn.rebuilding() ->
        {:error, "#{name} can't be removed while your tools are rebuilt; try again in a moment."}

      running?(dyn.generation, data["module"]) ->
        propose_removal(tool)

      true ->
        forget(tool)
    end
  end

  def remove(tool), do: forget(tool)

  defp running?(n, module) do
    case Dyn.generation(n) do
      {:ok, gen} -> has_tool?(gen, module)
      {:error, _} -> false
    end
  end

  defp forget(tool) do
    :ok = Library.delete_tool(tool)
    {:ok, :removed}
  end

  defp propose_removal(%Tool{name: name, data: data} = tool) do
    current = Dyn.status().generation
    modules = [data["module"] | if(data["screen"], do: [@ns <> data["screen"]], else: [])]

    with :ok <- Dyn.stage_reset(),
         :ok <- delete_files(files(Dyn.sources(current), modules)),
         {:ok, %{n: n}} <- Dyn.propose("Removes #{name}") do
      review(n, %{
        description: tool.description,
        conversation_id: tool.conversation_id,
        model: tool.model
      })
    else
      {:error, reason} -> {:error, "#{name} couldn't be removed: #{describe(reason)}"}
    end
  end

  defp delete_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case Dyn.stage_delete(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @typedoc "How a built tool is doing (`status/1`)."
  @type status ::
          :sample
          | :probation
          | :running
          | :starting
          | :safe_mode
          | :missing
          | {:reverted, String.t()}
          | {:change_reverted, String.t()}
          | {:removal_reverted, String.t()}

  @doc """
  How built `tool` is doing: the storyboard's `:sample`; a Workshop tool
  `:probation` (the version shown is on probation) or `:running`; its
  last change reverted while an earlier version runs
  (`{:change_reverted, why}`), or its removal reverted, so it runs again
  (`{:removal_reverted, why}`); reverted with no version left
  (`{:reverted, why}`); `:starting` while its generation is rebuilt for a
  new app version; `:safe_mode`; or `:missing`.
  """
  @spec status(Tool.t()) :: status()
  def status(%Tool{kind: "dyn", data: data}) do
    gen = data["generation"]
    dyn = Dyn.status()
    last = List.last(versions(data)) || %{"generation" => gen}

    case {Dyn.lookup({:tool, data["tool"]}), reverted(last["generation"])} do
      {{:ok, _}, nil} when dyn.generation == gen and dyn.status == :probation -> :probation
      {{:ok, _}, nil} -> :running
      {{:ok, _}, why} -> undone(last, why)
      {:error, why} -> not_running(dyn, why)
    end
  end

  def status(_tool), do: :sample

  # The tool runs, but its newest version was reverted.
  defp undone(%{"removed" => true}, why), do: {:removal_reverted, why}
  defp undone(_version, why), do: {:change_reverted, why}

  # The tool doesn't run: safe mode, a rebuild, a revert, or gone.
  defp not_running(%{mode: :safe}, _why), do: :safe_mode
  defp not_running(_dyn, nil), do: if(Dyn.rebuilding(), do: :starting, else: :missing)
  defp not_running(_dyn, why), do: {:reverted, why}

  defp reverted(n) when is_integer(n) do
    case Dyn.generation(n) do
      {:ok, %{status: :reverted, reason: reason}} -> reason || "reverted"
      _ -> nil
    end
  end

  defp reverted(_n), do: nil

  @doc "A short reason for the user (rho's errors are atoms and tuples)."
  @spec describe(term()) :: String.t()
  def describe(%{stage: stage, reason: reason}), do: "its #{stage} step refused it: #{reason}"
  def describe(:no_changes), do: "nothing would change"
  def describe(:proposal_limit), do: "too many proposals since the app started; restart it first"
  def describe(:rebuilding), do: "your tools are still being rebuilt for this version of Bezalel"
  def describe(:not_running), do: "building tools isn't running"
  def describe(:approval_required), do: "it wasn't approved in time; approve it again"
  def describe(:not_pending), do: "it was replaced by a newer proposal"

  def describe({:stale, _}),
    do: "what runs changed since it was proposed (a revert); build it again"

  def describe(reason) when is_binary(reason), do: reason
  def describe(reason), do: inspect(reason, limit: 10, printable_limit: 200)
end
