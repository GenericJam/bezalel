defmodule Bezalel.Test.Dyn do
  @moduledoc """
  The Dyn layer for tests that build tools: the app's Keeper (under
  `Rho.Supervisor`, test_helper.exs) moved to a directory of the test's
  own and back, simulated app restarts, and proposing sources directly.

  Dyn compiles into the one VM-wide code server and the Keeper is the
  app's, so these tests are `async: false`; every module of the namespace
  is purged when the Keeper moves.
  """

  import ExUnit.Assertions
  import ExUnit.Callbacks

  alias Rho.Dyn
  alias Rho.Dyn.{Compiler, Keeper, Store}

  @doc """
  Restarts the Keeper on `dir` (a fresh install: generation 0) for this
  test, and back on the app's directory when it ends.
  """
  @spec fresh(Path.t()) :: :ok
  def fresh(dir) do
    original = Application.get_env(:rho, :dyn)
    restart(Keyword.put(original, :dir, dir))
    on_exit(fn -> restart(original) end)
    :ok
  end

  @doc """
  A new launch on the same directory: the current one reaches stable
  (its first frame and ten seconds, or the user leaving), then the app
  stops (the Keeper, and every Dyn module with the VM) and starts again.
  """
  @spec relaunch() :: map()
  def relaunch, do: restart(Application.get_env(:rho, :dyn))

  defp restart(env) do
    _ = Keeper.mark_stable(Keeper)
    :ok = Supervisor.terminate_child(Rho.Supervisor, Keeper)
    purge_all()
    Application.put_env(:rho, :dyn, env)
    # A launch's state outlives a Keeper restart within the VM; a new VM
    # starts without it.
    dir = env[:dir] || Store.default_root()
    :persistent_term.erase({Keeper, Keeper, dir})
    {:ok, _} = Supervisor.restart_child(Rho.Supervisor, Keeper)
    Dyn.boot()
  end

  @doc "Purges every loaded module of the Dyn namespace (the generations' and protocol implementations for them)."
  @spec purge_all() :: :ok
  def purge_all do
    for {mod, _} <- :code.all_loaded(),
        String.starts_with?(Atom.to_string(mod), "Elixir.Bezalel.Dyn.") or
          Compiler.generation_of(mod) != nil do
      :code.purge(mod)
      :code.delete(mod)
      :code.purge(mod)
    end

    :ok
  end

  @doc "Stages `files` over the current generation and proposes them; returns the proposal's number."
  @spec propose!(%{String.t() => String.t()}, String.t()) :: pos_integer()
  def propose!(files, rationale \\ "test change") do
    :ok = Dyn.stage_reset()
    Enum.each(files, fn {path, source} -> :ok = Dyn.stage_put(path, source) end)
    assert {:ok, %{n: n}} = Dyn.propose(rationale)
    n
  end

  @doc "Waits for `{:rho_dyn, %{type: type}}`, dropping other Dyn events."
  @spec await(atom(), timeout()) :: map()
  def await(type, timeout \\ 5_000) do
    receive do
      {:rho_dyn, %{type: ^type} = event} -> event
      {:rho_dyn, _other} -> await(type, timeout)
    after
      timeout -> flunk("no #{type} event")
    end
  end
end
