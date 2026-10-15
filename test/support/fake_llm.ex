defmodule Bezalel.Test.FakeLLM do
  @moduledoc """
  A scripted `Rho.LLM` (rho's test fake): each model call takes the next
  reply from the script and plays its steps through the loop's sink.

  Steps: `{:text, s}`, `{:thinking, s}`, `{:tool_call, id, name, args}`,
  `{:sleep, ms}`, `:block` (never returns; the loop must kill it),
  `{:error, error}` (returns it).

  Every call sends the test `{:llm_request, request}`.
  """
  @behaviour Rho.LLM

  @doc "A script holder; `test` gets the requests."
  @spec start([[term()]], pid()) :: {:ok, pid()}
  def start(script, test \\ self()),
    do: Agent.start_link(fn -> %{script: script, test: test} end)

  @impl true
  def stream(request, agent, sink) do
    {reply, test} =
      Agent.get_and_update(agent, fn
        %{script: [reply | rest]} = st -> {{reply, st.test}, %{st | script: rest}}
        %{script: []} = st -> {{:exhausted, st.test}, st}
      end)

    send(test, {:llm_request, request})

    case reply do
      :exhausted -> {:error, {:other, "fake script exhausted"}}
      steps -> play(steps, sink, %{text: "", thinking: "", tool_calls: []})
    end
  end

  defp play([], _sink, acc),
    do:
      {:ok, Map.merge(acc, %{usage: %{input_tokens: 10, output_tokens: 5}, finish_reason: :stop})}

  defp play([step | rest], sink, acc) do
    case step do
      {:text, s} ->
        sink.({:text, s})
        play(rest, sink, %{acc | text: acc.text <> s})

      {:thinking, s} ->
        sink.({:thinking, s})
        play(rest, sink, %{acc | thinking: acc.thinking <> s})

      {:tool_call, id, name, args} ->
        call = %{"id" => id, "name" => name, "arguments" => args}
        play(rest, sink, %{acc | tool_calls: acc.tool_calls ++ [call]})

      {:sleep, ms} ->
        Process.sleep(ms)
        play(rest, sink, acc)

      :block ->
        Process.sleep(:infinity)

      {:error, error} ->
        {:error, error}
    end
  end
end
