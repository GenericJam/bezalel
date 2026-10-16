defmodule Bezalel.Workshop.Builder do
  @moduledoc """
  The Workshop's live build: a rho loop (`Rho.Loop`) on the chosen model
  with the Workshop's prompt (`Bezalel.Workshop.Prompt`) and the
  registry's tools (the study tools, the `dyn_*` tools that write and
  propose Dyn code, and the current generation's own), asked to build
  what the user described. It runs in the caller (the screen's build
  task), which subscribes to the loop and follows it to the end, reporting
  the build's steps (`Bezalel.Workshop.steps/1`) as the loop writes code
  (`dyn_write`, `dyn_edit`, ...) and proposes it (`dyn_propose`).

  The result is the generation the run proposed (pending the user's
  approval, `Bezalel.Workshop.approve/1`) or why there is none: the model
  call failed, or the model stopped without a proposal (its last words
  say why, typically a check it couldn't satisfy).

  The loop's session is kept in `workshop` under rho's data dir (not with
  the conversations). The loop is linked to the caller, so a build task
  that is stopped takes its loop with it; it is shut when the build ends.
  Loop options from `config :bezalel, Bezalel.Workshop.Builder` are added
  to the loop's (tests set `:llm` to a scripted model).
  """

  alias Bezalel.Workshop.Prompt
  alias Rho.{Loop, Session}

  @writes ~w(dyn_write dyn_edit dyn_copy dyn_delete)
  # Writing, reading the data, proposing, fixing and proposing again.
  @max_iterations 24
  # Silence from the loop this long ends the build (each model call and
  # tool has its own, shorter timeout).
  @quiet_ms 300_000

  @type outcome ::
          {:ok, %{n: pos_integer(), summary: String.t(), session: String.t()}}
          | {:error, String.t()}

  @doc """
  Runs the build of `request` (`Bezalel.Workshop.Prompt.request/2`) on
  `model` (a `Bezalel.Models` id, rho's model spec). `on_step.(i)` fires as
  step `i` of the live steps starts. Staging starts as the generation that
  runs, so nothing a discarded, refused or reverted build left there rides
  along.
  """
  @spec build(String.t(), String.t(), (non_neg_integer() -> any())) :: outcome()
  def build(request, model, on_step) do
    on_step.(0)

    with :ok <- Rho.Dyn.stage_reset(),
         {:ok, loop} <- start(model) do
      run(loop, request, on_step)
    else
      {:error, reason} -> {:error, "The build couldn't start: #{inspect(reason)}"}
    end
  end

  defp run(loop, request, on_step) do
    Process.link(loop)

    try do
      session = Loop.config(loop).session.id
      :ok = Loop.subscribe(loop)
      :ok = Loop.prompt(loop, request)
      follow(session, on_step, %{proposed: false, text: "", error: nil})
    after
      Process.unlink(loop)
      shut(loop)
    end
  end

  @doc "The directory the builds' sessions are kept in."
  @spec dir() :: Path.t()
  def dir, do: Path.join(Rho.Config.data_dir(), "workshop")

  defp start(model) do
    File.mkdir_p!(dir())

    opts =
      [
        session: Session.new(dir(), model, Rho.Config.data_dir()),
        entries: [],
        system_prompt: Prompt.system_prompt(),
        tools: :registry,
        max_iterations: @max_iterations
      ] ++ Application.get_env(:bezalel, __MODULE__, [])

    Rho.start_loop(opts)
  end

  defp follow(session, on_step, acc) do
    receive do
      {:rho, ^session, event} ->
        case event(event, on_step, acc) do
          {:done, reason, acc} -> outcome(reason, session, on_step, acc)
          acc -> follow(session, on_step, acc)
        end
    after
      @quiet_ms -> {:error, "The build stopped: the model went quiet."}
    end
  end

  defp event(%{type: :turn_start}, _on_step, acc), do: %{acc | text: ""}

  defp event(%{type: :message_update, kind: :text, delta: delta}, _on_step, acc),
    do: %{acc | text: acc.text <> delta}

  defp event(%{type: :tool_execution_start, name: name}, on_step, acc) when name in @writes do
    on_step.(1)
    acc
  end

  defp event(%{type: :tool_execution_start, name: "dyn_propose"}, on_step, acc) do
    on_step.(2)
    acc
  end

  # dyn_propose answers "Proposed generation G<n> (on top of G<p>): ...".
  defp event(
         %{type: :tool_execution_end, name: "dyn_propose", is_error: false, text: text},
         _on_step,
         acc
       ) do
    case String.split(text, "Proposed generation G", parts: 2) do
      [_, rest] -> %{acc | proposed: rest |> Integer.parse() |> elem(0)}
      _ -> acc
    end
  end

  defp event(%{type: :turn_end, error: error}, _on_step, acc) when is_binary(error),
    do: %{acc | error: error}

  defp event(%{type: :agent_end, reason: reason}, _on_step, acc), do: {:done, reason, acc}
  defp event(_event, _on_step, acc), do: acc

  # Only the generation this build proposed: another proposal (a Remove
  # made meanwhile) may have replaced it.
  defp outcome(_reason, session, on_step, %{proposed: n} = acc) when is_integer(n) do
    if Rho.Dyn.status().pending == n do
      on_step.(3)
      {:ok, %{n: n, summary: String.trim(acc.text), session: session}}
    else
      {:error, "The tool was proposed, but a newer proposal replaced it."}
    end
  end

  defp outcome(:error, _session, _on_step, acc),
    do: {:error, "The model call failed: #{acc.error || "no reason given"}"}

  defp outcome(:stopped, _session, _on_step, _acc), do: {:error, "The build was stopped."}

  defp outcome(:max_iterations, _session, _on_step, _acc),
    do: {:error, "The build ran out of steps before it had a tool that passed its checks."}

  defp outcome(_reason, _session, _on_step, acc) do
    case String.trim(acc.text) do
      "" -> {:error, "The model finished without proposing a tool."}
      text -> {:error, "No tool was proposed. The model said: " <> text}
    end
  end

  defp shut(loop) do
    _ = DynamicSupervisor.terminate_child(Rho.LoopSup, loop)
    :ok
  catch
    :exit, _ -> :ok
  end
end
