defmodule Bezalel.AppScreenTest do
  use Mob.ScreenCase
  # Shares the test database and Mob.State with the other modules' setup.
  @moduletag :screen

  alias Bezalel.{AppScreen, Library, Repo}
  alias Bezalel.Library.{Conversation, Message, Tool}

  setup do
    for schema <- [Message, Tool, Conversation], do: Repo.delete_all(schema)
    Mob.State.delete(:bezalel_conversation)
    Mob.State.delete(:bezalel_mode)
    :ok
  end

  test "first launch opens the worked Exodus 31 study, and every tab renders what the natives can draw" do
    view = mount_screen(AppScreen)
    assert assigns(view).conversation.name == "Exodus 31 · Bezalel"
    assert text(view) =~ "SERMON PREP · EXODUS 31"

    for tab <- [:convs, :workshop, :settings, :study] do
      view = render_info(view, {:tap, {:tab, tab}})
      assert_renderable(view)
    end
  end

  test "asking adds the question and the agent's reply, with its summary open" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:change, :draft, "What does “skill” mean?"})
    view = render_info(view, {:tap, {:study, :send}})

    assert assigns(view).typing
    assert assigns(view).draft == ""

    view = render_async(view)
    [question, reply] = Enum.take(assigns(view).messages, -2)
    assert question.text == "What does “skill” mean?"
    assert %{role: :agent, model: "sonnet"} = reply
    assert MapSet.member?(assigns(view).expanded, "#{reply.id}:sum")
    assert text(view) =~ "ḥokmâ"
  end

  test "deleting the last reply offers Undo and Ask again; Undo puts it back" do
    view = mount_screen(AppScreen)
    last = List.last(assigns(view).messages)

    view = render_info(view, {:tap, {:study, {:delete, last.id}}})
    assert %{undo: %Message{id: id}, ask_again: true} = assigns(view).toast
    assert id == last.id
    refute Enum.any?(assigns(view).messages, &(&1.id == last.id))

    view = render_info(view, {:tap, {:study, :undo}})
    assert List.last(assigns(view).messages).id == last.id
    assert assigns(view).toast == nil
  end

  test "deleting further up asks first, and keeping it changes nothing" do
    view = mount_screen(AppScreen)
    first = hd(assigns(view).messages)
    count = length(assigns(view).messages)

    view = render_info(view, {:tap, {:study, {:delete, first.id}}})
    assert assigns(view).sheet == {:confirm_delete, first.id}

    view = render_info(view, {:tap, :sheet})
    assert length(assigns(view).messages) == count

    view = render_info(view, {:tap, {:study, {:delete, first.id}}})
    view = render_info(view, {:tap, {:study, {:confirm_delete, first.id}}})
    assert length(assigns(view).messages) == count - 1
  end

  test "building from the chat saves the sermon outline and opens it" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:tap, {:study, :build_from_chat}})
    assert assigns(view).tab == :workshop
    assert assigns(view).desc =~ "Exodus 31:2–3"

    view = render_info(view, {:tap, {:workshop, :build}})
    view = render_async(view)

    assert assigns(view).tab == :tool
    assert %Tool{name: "Sermon Outline"} = Library.get_tool(assigns(view).tool_id)
    assert text(view) =~ "God fills ordinary hands for holy work."
  end

  test "a new conversation opens empty and becomes the open one on the shelf" do
    view = mount_screen(AppScreen)
    view = render_info(view, {:change, :draft, "half-typed"})
    view = render_info(view, {:tap, {:convs, :new}})

    assert assigns(view).messages == []
    assert assigns(view).draft == ""

    view = render_info(view, {:tap, {:tab, :convs}})
    assert text(view) =~ "New study"
    assert text(view) =~ "OPEN"
  end
end
