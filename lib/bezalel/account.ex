defmodule Bezalel.Account do
  @moduledoc """
  What Settings shows of the user's model access, read from rho: per
  provider, the sign-in or API key (`Rho.Auth`, kept in the secure store),
  and the tokens the model calls used (`Rho.Usage`). Keys never leave
  here whole: `status/0` carries a masked form only.
  """

  alias Rho.Auth

  @subscriptions [:anthropic, :openai_codex]
  @api_keys [:anthropic, :openai, :google]

  @type access :: %{
          signed_in: boolean(),
          type: :oauth | :api_key | nil,
          email: String.t() | nil,
          masked: String.t() | nil
        }

  @doc "The providers a subscription signs in to, in the order Settings lists them."
  @spec subscriptions() :: [Auth.provider()]
  def subscriptions, do: @subscriptions

  @doc "The providers that take an API key, in the order Settings lists them."
  @spec api_keys() :: [Auth.provider()]
  def api_keys, do: @api_keys

  @doc ~s(The subscription's name: "Claude", "ChatGPT".)
  @spec subscription_name(Auth.provider()) :: String.t()
  def subscription_name(:anthropic), do: "Claude"
  def subscription_name(:openai_codex), do: "ChatGPT"

  @doc ~s(The API key's provider: "Anthropic", "OpenAI", "Google Gemini".)
  @spec key_name(Auth.provider()) :: String.t()
  def key_name(:anthropic), do: "Anthropic"
  def key_name(:openai), do: "OpenAI"
  def key_name(:google), do: "Google Gemini"

  @doc """
  Per provider (`Rho.Auth.providers/0`): signed in or not, how, the
  sign-in's email, and an API key masked to its first and last characters.
  Also what `Bezalel.Models.groups/1` takes.
  """
  @spec status() :: %{Auth.provider() => access()}
  def status do
    Map.new(Auth.providers(), fn provider ->
      case Auth.get(provider) do
        {:ok, %{"type" => "api_key", "key" => key}} ->
          {provider, %{signed_in: true, type: :api_key, email: nil, masked: mask(key)}}

        {:ok, creds} ->
          {provider, %{signed_in: true, type: :oauth, email: creds["email"], masked: nil}}

        :error ->
          {provider, %{signed_in: false, type: nil, email: nil, masked: nil}}
      end
    end)
  end

  @doc """
  A key as Settings shows it: its first 6 and last 4 characters
  (`sk-ant…WXYZ`), or dots alone for a key too short to show any of.
  """
  @spec mask(String.t()) :: String.t()
  def mask(key) when byte_size(key) >= 16,
    do: String.slice(key, 0, 6) <> "…" <> String.slice(key, -4, 4)

  def mask(_key), do: "••••••••"

  @doc """
  Tokens per model (input, output and cache), today and in total, the
  biggest total first: `[%{model, today, total}]`. Empty before any call.
  Calls recorded under an alias or a dated snapshot of one catalog model
  count as that model (`model` is then its catalog id).
  """
  @spec usage(Date.t()) :: [
          %{model: String.t(), today: non_neg_integer(), total: non_neg_integer()}
        ]
  def usage(today \\ Rho.Budget.today()) do
    state = Rho.Usage.load(Rho.Config.data_dir())
    day = Rho.Usage.by_model(state, today)

    state
    |> Rho.Usage.by_model(:total)
    |> Enum.group_by(
      fn {spec, _} -> spec |> Bezalel.Models.lookup() |> then(&((&1 && &1.id) || spec)) end,
      fn {spec, counters} -> {tokens(day[spec]), tokens(counters)} end
    )
    |> Enum.map(fn {model, figures} ->
      %{
        model: model,
        today: figures |> Enum.map(&elem(&1, 0)) |> Enum.sum(),
        total: figures |> Enum.map(&elem(&1, 1)) |> Enum.sum()
      }
    end)
    |> Enum.sort_by(&{-&1.total, &1.model})
  end

  defp tokens(nil), do: 0

  defp tokens(counters),
    do: Enum.sum(for k <- ~w(input output cacheRead cacheWrite), do: counters[k] || 0)
end
