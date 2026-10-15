defmodule Bezalel.Agent.Live do
  @moduledoc """
  The live study agent: rho's loop (`Rho.Loop`) with the study system
  prompt (`Bezalel.Study.Prompt`) and the tier 1 study tools
  (`Bezalel.Study.Tools.tier1/0`, plus rho's `read_artifact` for a result
  too long to send whole), on the model chosen in Settings.

  **One loop per conversation being answered**, started on its first
  question and registered under the conversation's id
  (`Bezalel.Agent.Live`'s `Registry`, which the app starts). It stays
  while the conversation is open, so later questions reuse its context
  (tool results included, and the provider's prompt cache). The screen
  releases it (`release/1`) when the conversation is left and its reply
  is done, when a message in it is deleted or put back, and before
  retrying a failed reply; mounting the screen releases them all.

  **History.** Bezalel's Library is the record of a conversation until
  conversations move onto rho's sessions (bezalel-y77.3). A new loop's
  session is seeded from the Library: each user message, and each reply
  as its SUMMARY (THINKING and TOOL CALL blocks are the reply's working,
  not its answer). Seeding instead of keeping a rho session per
  conversation keeps the promise the delete toast makes ("The agent
  won't see it": a released loop is re-seeded without it), works for
  every conversation stored before the agent was live, and leaves nothing
  to migrate when y77.3 makes the session the transcript. The session file
  is scratch: it's deleted with the loop.

  Loop options from `config :bezalel, Bezalel.Agent.Live` are added to
  the loop's (tests set `:llm` to a scripted model).
  """
  @behaviour Bezalel.Agent

  alias Bezalel.Study.{Prompt, Tools}
  alias Rho.{Loop, Session}

  @registry __MODULE__

  @doc "Starts the registry the loops are named in (the app does, after `Rho.Supervisor`)."
  @spec start_link() :: {:ok, pid()} | {:error, term()}
  def start_link, do: Registry.start_link(keys: :unique, name: @registry)

  @doc "The tools a loop offers."
  @spec tools() :: [module()]
  def tools, do: Tools.tier1() ++ [Rho.Tools.ReadArtifact]

  @impl true
  def ask(conversation_id, messages, model, subscriber) do
    {earlier, question} = split_question(messages)

    with {:ok, loop} <- loop(conversation_id, earlier, model),
         :ok <- Loop.subscribe(loop, subscriber),
         :ok <- use_model(loop, model),
         :ok <- Loop.prompt(loop, question) do
      {:ok, Loop.config(loop).session.id}
    end
  end

  @impl true
  def steer(conversation_id, text) do
    case whereis(conversation_id) do
      nil -> {:error, :idle}
      loop -> Loop.steer(loop, text)
    end
  end

  @impl true
  def stop(conversation_id) do
    case whereis(conversation_id) do
      nil -> :ok
      loop -> Loop.stop(loop)
    end
  end

  @impl true
  def release(conversation_id) do
    case whereis(conversation_id) do
      nil -> :ok
      loop -> shut(loop)
    end
  end

  @impl true
  def release_all do
    for {_id, loop, _} <- Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [:"$_"]}]),
        do: shut(loop)

    :ok
  end

  defp whereis(conversation_id) do
    case Registry.lookup(@registry, conversation_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp loop(conversation_id, earlier, model) do
    case whereis(conversation_id) do
      nil -> start(conversation_id, earlier, model)
      loop -> {:ok, loop}
    end
  end

  defp start(conversation_id, earlier, model) do
    {session, entries} = seed(Session.new(Session.dir(), model, Rho.Config.data_dir()), earlier)

    opts =
      [
        session: session,
        entries: entries,
        name: {:via, Registry, {@registry, conversation_id}},
        system_prompt: Prompt.system_prompt(),
        tools: tools()
      ] ++ Application.get_env(:bezalel, __MODULE__, [])

    case Rho.start_loop(opts) do
      {:ok, loop} ->
        {:ok, loop}

      # Asked twice at once: the other call's loop.
      {:error, {:already_started, loop}} ->
        File.rm(session.path)
        {:ok, loop}

      {:error, _} = error ->
        File.rm(session.path)
        error
    end
  end

  # The question is the user messages after the last reply (one, unless a
  # reply failed or was deleted in between).
  defp split_question(messages) do
    {question, earlier} =
      messages |> Enum.reverse() |> Enum.split_while(&(&1.role == :user))

    {Enum.reverse(earlier), question |> Enum.reverse() |> Enum.map_join("\n\n", & &1.text)}
  end

  # The Library's messages as session entries: user text, and each reply's
  # summary; consecutive ones of a role joined.
  defp seed(session, messages) do
    messages
    |> Enum.map(&{&1.role, seed_text(&1)})
    |> Enum.reject(fn {_role, text} -> text == "" end)
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn [{role, _} | _] = chunk ->
      text = Enum.map_join(chunk, "\n\n", &elem(&1, 1))

      if role == :user,
        do: Session.user(text),
        else: Session.assistant(%{text: text, stop_reason: "stop"}, session.model)
    end)
    |> Enum.map_reduce(session, fn entry, s ->
      {s, written} = Session.append(s, entry)
      {written, s}
    end)
    |> then(fn {entries, session} -> {session, entries} end)
  end

  defp seed_text(%{role: :user, text: text}), do: text || ""

  defp seed_text(%{blocks: blocks}) do
    Enum.find_value(blocks, "", fn b ->
      if b["id"] == "sum", do: String.trim(summary_text(b))
    end)
  end

  # A block whose header was cut repeats the whole text under it.
  defp summary_text(%{"cut" => true, "rest" => rest}), do: rest
  defp summary_text(%{"first" => first, "rest" => rest}), do: first <> " " <> rest

  defp use_model(loop, model) do
    if Loop.config(loop).session.model == model,
      do: :ok,
      else: Loop.set_model(loop, model)
  end

  defp shut(loop) do
    %{session: session} = Loop.config(loop)
    _ = DynamicSupervisor.terminate_child(Rho.LoopSup, loop)
    File.rm(session.path)
    File.rm_rf(Path.join([Rho.Config.data_dir(), "artifacts", session.id]))
    :ok
  catch
    # Gone already (it ended, or another caller shut it).
    :exit, _ -> :ok
  end
end
