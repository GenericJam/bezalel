defmodule Bezalel.Agent do
  @moduledoc """
  The study agent: given a conversation's messages and the chosen model,
  produces the next reply as blocks (THINKING / TOOL CALL / SUMMARY) and,
  when it cites one, a passage.

  The implementation is picked by `config :bezalel, :agent`. Until a model
  connection exists it is `Bezalel.Agent.Storyboard`, the scripted replies of
  the Core Screens v2 design; the Settings model section says so.
  """

  @type reply :: %{blocks: [map()], passage: String.t() | nil}

  @callback reply(messages :: [Bezalel.Library.Message.t()], model :: map()) ::
              {:ok, reply()} | {:error, term()}

  @doc "Whether replies come from a real model (false for the storyboard)."
  @callback live?() :: boolean()

  @doc "The next reply for `messages`, from the configured implementation."
  @spec reply([Bezalel.Library.Message.t()], map()) :: {:ok, reply()} | {:error, term()}
  def reply(messages, model), do: impl().reply(messages, model)

  @doc "Whether replies come from a real model."
  @spec live?() :: boolean()
  def live?, do: impl().live?()

  defp impl, do: Application.get_env(:bezalel, :agent, Bezalel.Agent.Storyboard)
end
