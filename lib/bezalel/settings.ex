defmodule Bezalel.Settings do
  @moduledoc """
  The user's choices, kept in `Mob.State` (survives restarts): theme mode,
  cover, model, sign-in, and which conversation is open.
  """

  @modes [:light, :dark, :night, :system]
  @covers [:leather, :paper]

  @doc "Theme modes in the order the Theme control lists them."
  @spec modes() :: [atom()]
  def modes, do: @modes

  @doc "Bar treatments."
  @spec covers() :: [atom()]
  def covers, do: @covers

  @spec mode() :: atom()
  def mode, do: get(:mode, :dark, @modes)

  @spec cover() :: atom()
  def cover, do: get(:cover, :leather, @covers)

  @spec model() :: String.t()
  def model, do: Mob.State.get(:bezalel_model, Bezalel.Models.default())

  @spec signed_in?() :: boolean()
  def signed_in?, do: Mob.State.get(:bezalel_signed_in, false)

  @spec conversation_id() :: integer() | nil
  def conversation_id, do: Mob.State.get(:bezalel_conversation, nil)

  def put_mode(mode) when mode in @modes, do: Mob.State.put(:bezalel_mode, mode)
  def put_cover(cover) when cover in @covers, do: Mob.State.put(:bezalel_cover, cover)
  def put_model(id) when is_binary(id), do: Mob.State.put(:bezalel_model, id)
  def put_signed_in(value) when is_boolean(value), do: Mob.State.put(:bezalel_signed_in, value)
  def put_conversation_id(id), do: Mob.State.put(:bezalel_conversation, id)

  @doc "The theme module for a mode."
  @spec theme_module(atom()) :: module()
  def theme_module(:system), do: MobBezalel.System
  def theme_module(mode), do: MobBezalel.theme_module(mode)

  defp get(key, default, allowed) do
    value = Mob.State.get(:"bezalel_#{key}", default)
    if value in allowed, do: value, else: default
  end
end
