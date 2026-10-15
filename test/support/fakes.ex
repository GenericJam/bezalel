defmodule Bezalel.Test.MemoryStore do
  @moduledoc "rho's credential store in tests: an ETS table instead of a keychain."
  @behaviour Rho.CredentialStore

  @table __MODULE__

  @doc "Creates the table (owned by the caller, which must outlive the tests)."
  def start, do: :ets.new(@table, [:named_table, :public, :set])

  @doc "Forgets every stored value."
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def get(key) do
    case :ets.lookup(@table, key) do
      [{^key, value}] -> {:ok, value}
      [] -> :error
    end
  end

  @impl true
  def put(key, value) do
    :ets.insert(@table, {key, value})
    :ok
  end

  @impl true
  def delete(key) do
    :ets.delete(@table, key)
    :ok
  end
end

defmodule Bezalel.Test.Browser do
  @moduledoc "rho's `:open_url` in tests: the opened URL is kept, not opened."

  @table __MODULE__

  def start, do: :ets.new(@table, [:named_table, :public, :set])

  def open(url) do
    :ets.insert(@table, {:last, url})
    :ok
  end

  @doc "The last URL opened, or nil."
  def last do
    case :ets.lookup(@table, :last) do
      [{:last, url}] -> url
      [] -> nil
    end
  end
end
