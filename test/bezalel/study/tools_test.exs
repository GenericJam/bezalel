defmodule Bezalel.Study.ToolsTest do
  # What the model is told must match what it has: every tool the
  # descriptions or the system prompt name is one Bezalel offers.
  use ExUnit.Case, async: true

  alias Bezalel.Study.{Prompt, Tools}

  @names Enum.map(Tools.tier1(), & &1.name())

  # `snake_case` names in backticks that look like tool names.
  defp tools_named(text) do
    for [_, name] <- Regex.scan(~r/`([a-z]+(?:_[a-z]+)+)`/, text),
        String.match?(
          name,
          ~r/^(lookup|word|search|get|parse|people|find|explore|graph|compare|list)_/
        ),
        uniq: true,
        do: name
  end

  test "every tool is a rho tool the model can be offered, under a unique name" do
    for tool <- Tools.tier1() do
      assert Rho.Tool.tool?(tool)
      assert %ReqLLM.Tool{} = Rho.Tool.to_req_llm(tool)
    end

    assert Enum.count(Enum.uniq(@names)) == 9
  end

  test "tool descriptions point only at tools Bezalel has" do
    for tool <- Tools.tier1() do
      assert tools_named(tool.description()) -- @names == [], tool.name()
    end
  end

  test "the system prompt covers every tool and names no other" do
    named = tools_named(Prompt.system_prompt())
    assert named -- @names == []
    assert @names -- named == []
  end

  test "every hint lookup_verse gives names a tool Bezalel has" do
    {:ok, text} = Tools.LookupVerse.run(%{"reference" => "Exodus 31:2-3"}, %{})
    assert tools_named(text) -- @names == []
  end
end
