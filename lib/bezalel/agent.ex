defmodule Bezalel.Agent do
  @moduledoc """
  The study agent: answers a conversation's question as the design's
  blocks (THINKING / TOOL CALL / SUMMARY) and, when it cites one, a
  passage.

  Replies are live once the user has a model: a sign-in or an API key for
  any provider (`live?/1`). The live agent is picked by
  `config :bezalel, :agent` (`Bezalel.Agent.Live`, rho's loop with the
  study tools); it streams rho's loop events (`{:rho, session_id, event}`,
  `Rho.Events`) to the screen, which folds them into blocks
  (`Bezalel.Agent.Reply`). Without a model, or with `:agent` set to nil,
  replies come from the design's script (`Bezalel.Agent.Storyboard`), and
  the screens say so.
  """

  @doc """
  Asks the next reply of `conversation_id`: `messages` are its messages,
  ending with the question (the user messages after the last reply).
  `model` is a `Bezalel.Models` id. The loop's events go to `subscriber`.
  Returns the loop's session id, which the events carry.
  """
  @callback ask(
              conversation_id :: integer(),
              messages :: [Bezalel.Library.Message.t()],
              model :: String.t(),
              subscriber :: pid()
            ) :: {:ok, String.t()} | {:error, term()}

  @doc "Adds `text` to the reply in progress (rho's steering); `{:error, :idle}` without one."
  @callback steer(conversation_id :: integer(), text :: String.t()) :: :ok | {:error, :idle}

  @doc "Stops the reply in progress, if any."
  @callback stop(conversation_id :: integer()) :: :ok

  @doc """
  Forgets the conversation's agent state, so its next reply starts from
  the conversation as stored (after a delete or an undo, or once it's no
  longer open).
  """
  @callback release(conversation_id :: integer()) :: :ok

  @doc "Forgets every conversation's agent state."
  @callback release_all() :: :ok

  @doc """
  Whether replies come from a model: a live agent is configured and
  `account` (`Bezalel.Account.status/0`) has a sign-in or an API key.
  """
  @spec live?(map()) :: boolean()
  def live?(account) do
    impl() != nil and Enum.any?(account, fn {_provider, access} -> access.signed_in end)
  end

  @doc "See the `c:ask/4` callback."
  @spec ask(integer(), [Bezalel.Library.Message.t()], String.t(), pid()) ::
          {:ok, String.t()} | {:error, term()}
  def ask(conversation_id, messages, model, subscriber),
    do: impl().ask(conversation_id, messages, model, subscriber)

  @doc "See the `c:steer/2` callback."
  @spec steer(integer(), String.t()) :: :ok | {:error, :idle}
  def steer(conversation_id, text), do: impl().steer(conversation_id, text)

  @doc "See the `c:stop/1` callback."
  @spec stop(integer()) :: :ok
  def stop(conversation_id), do: impl().stop(conversation_id)

  @doc "See the `c:release/1` callback; nothing without a live agent."
  @spec release(integer()) :: :ok
  def release(conversation_id) do
    if impl(), do: impl().release(conversation_id), else: :ok
  end

  @doc "See the `c:release_all/0` callback; nothing without a live agent."
  @spec release_all() :: :ok
  def release_all, do: if(impl(), do: impl().release_all(), else: :ok)

  defp impl, do: Application.get_env(:bezalel, :agent, Bezalel.Agent.Live)
end
