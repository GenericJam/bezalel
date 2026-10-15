defmodule Bezalel.AgentWorkshopTest do
  use ExUnit.Case, async: false

  alias Bezalel.Agent.Storyboard
  alias Bezalel.Library
  alias Bezalel.Library.{Conversation, Message, Tool}
  alias Bezalel.{Repo, Workshop}

  setup do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)
    :ok
  end

  defp ask(text),
    do: Storyboard.reply([%Message{role: :user, text: text}], Bezalel.Models.get("sonnet"))

  test "a question about a lexicon word gets that word's Hebrew, Strong's number and cross-references" do
    {:ok, %{blocks: blocks}} = ask("Tell me about “Spirit of God”")
    summary = Enum.find(blocks, &(&1["id"] == "sum"))

    assert summary["first"] =~ "“Spirit of God” translates רוּחַ (rûaḥ, H7307)"
    assert summary["rest"] =~ "Gen 1:2, Num 11:25, Isa 11:2, Acts 2:3"
    assert Enum.any?(blocks, &(&1["type"] == "TOOL CALL" and &1["first"] == "lexicon(H7307)"))
  end

  test "the word sheet's question (the transliteration) finds the word too" do
    {:ok, %{blocks: blocks, by: "storyboard"}} = ask("Tell me about “rûaḥ”")
    assert Enum.find(blocks, &(&1["id"] == "sum"))["first"] =~ "H7307"
  end

  test "any other question is placed in the commission of Bezalel" do
    {:ok, %{blocks: blocks}} = ask("What about Oholiab?")
    assert Enum.map(blocks, & &1["type"]) == ["THINKING", "SUMMARY"]
    assert Enum.find(blocks, &(&1["id"] == "sum"))["first"] =~ "“What about Oholiab?” sits inside"
  end

  test "it answers the latest user message, not an earlier one" do
    messages = [
      %Message{role: :user, text: "called"},
      %Message{role: :agent, blocks: []},
      %Message{role: :user, text: "What does skill mean?"}
    ]

    {:ok, %{blocks: blocks}} = Storyboard.reply(messages, Bezalel.Models.get("sonnet"))
    assert Enum.find(blocks, &(&1["id"] == "sum"))["first"] =~ "ḥokmâ"
  end

  test "the Workshop builds and saves the sermon outline, reporting every step" do
    {:ok, c} = Library.create_conversation(%{name: "Ex 31", kicker: "K", kind: "Sermon prep"})
    me = self()

    assert {:ok, tool} =
             Workshop.build(
               "A sermon outline helper for Exodus 31",
               c.id,
               "haiku",
               &send(me, {:step, &1})
             )

    assert %{
             name: "Sermon Outline",
             kind: "sermon_outline",
             model: "storyboard",
             conversation_id: cid
           } =
             tool

    assert cid == c.id
    assert [%{"num" => "I"}, %{"num" => "II"}, %{"num" => "III"}] = tool.data["moves"]
    assert [tool.id] == Enum.map(Library.list_tools(), & &1.id)

    steps = for _ <- Workshop.steps(), do: assert_received({:step, _})
    assert steps |> Enum.map(fn {:step, i} -> i end) |> Enum.uniq() == [0, 1, 2, 3]
  end

  test "without a model, any description builds the design's sample" do
    assert {:ok, tool} =
             Workshop.build("Reading plan: Lent, 40 days", nil, "sonnet", fn _ -> :ok end)

    assert %{name: "Sermon Outline", description: "Reading plan: Lent, 40 days"} = tool
    assert tool.data["text"] == "Exodus 31:1–11"
  end
end
