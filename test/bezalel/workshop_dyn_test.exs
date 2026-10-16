defmodule Bezalel.WorkshopDynTest do
  # The Workshop on rho's Dyn layer: a scripted model (Bezalel.Test.FakeLLM)
  # writes a tool and its screen, the user approves it, the study agent
  # calls it, its panel draws its screen; crashes on probation revert it;
  # the check refuses what a tool may not call; a restart keeps it. The
  # Keeper is the app's, moved to this test's own directory
  # (Bezalel.Test.Dyn), and the screen runs in the test process, so the
  # loops', the host's and the Keeper's messages arrive here.
  use Mob.ScreenCase
  @moduletag :screen
  @moduletag :tmp_dir

  alias Bezalel.Agent.Live
  alias Bezalel.{AppScreen, Library, Repo, Workshop}
  alias Bezalel.Library.{Conversation, Tool}
  alias Bezalel.Test.{Dyn, FakeLLM, MemoryStore}
  alias Bezalel.Workshop.{Builder, Host, Prompt}

  setup %{tmp_dir: dir} do
    for schema <- [Tool, Conversation], do: Repo.delete_all(schema)
    for key <- [:bezalel_conversation, :bezalel_mode, :bezalel_model], do: Mob.State.delete(key)
    MemoryStore.clear()
    :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-test-key-0123456789")
    :ok = Dyn.fresh(Path.join(dir, "dyn"))

    on_exit(fn ->
      Application.delete_env(:bezalel, Live)
      Application.delete_env(:bezalel, Builder)
      Bezalel.Agent.release_all()
    end)

    :ok
  end

  # A word-frequency card: the tool and its screen. `crash` makes the tool
  # raise for a reference ("boom") and the screen on the :boom tap.
  defp word_frequency(opts \\ []) do
    crash? = Keyword.get(opts, :crash, false)
    heading = Keyword.get(opts, :heading, "Most frequent words")

    """
    defmodule Bezalel.Dyn.WordFrequency do
      @behaviour Rho.Tool
      alias Bezalel.Workshop.Study

      @split [" ", ",", ".", ";", ":", "!", "?", "“", "”", "‘", "’", "(", ")"]

      def name, do: "word_frequency"
      def description, do: "The most frequent English (BSB) words of a passage, with counts."

      def parameter_schema,
        do: %{
          "type" => "object",
          "properties" => %{"reference" => %{"type" => "string"}},
          "required" => ["reference"]
        }

      #{if crash?, do: ~s|def run(%{"reference" => "boom"}, _ctx), do: raise("boom")|}

      def run(%{"reference" => ref}, _ctx) do
        with {:ok, p} <- Study.passage(ref), do: {:ok, format(counts(p))}
      end

      def counts(p) do
        p.verses
        |> Enum.flat_map(&String.split(String.downcase(&1.english), @split, trim: true))
        |> Enum.frequencies()
        |> Enum.sort_by(fn {w, n} -> {-n, w} end)
        |> Enum.take(5)
      end

      def format(counts), do: Enum.map_join(counts, ", ", fn {w, n} -> "\#{w} \#{n}" end)

      def selftest do
        p = %{verses: [%{english: "The Lord, the God."}]}
        if counts(p) == [{"the", 2}, {"god", 1}, {"lord", 1}], do: :ok, else: :error
      end
    end

    defmodule Bezalel.Dyn.WordFrequency.Screen do
      use Mob.Screen
      alias Bezalel.Dyn.WordFrequency
      alias Bezalel.Workshop.Study
      alias MobBezalel.UI

      def mount(_params, _session, socket),
        do: {:ok, Mob.Socket.assign(socket, ref: "Exodus 31:1-3", result: "")}

      def handle_info({:change, :ref, value}, socket),
        do: {:noreply, Mob.Socket.assign(socket, :ref, value)}

      #{if crash?, do: ~s|def handle_info({:tap, :boom}, _socket), do: raise("screen boom")|}

      def handle_info({:tap, :count}, socket) do
        result =
          case Study.passage(socket.assigns.ref) do
            {:ok, p} -> WordFrequency.format(WordFrequency.counts(p))
            {:error, message} -> message
          end

        {:noreply, Mob.Socket.assign(socket, :result, result)}
      end

      def handle_info(_message, socket), do: {:noreply, socket}

      def render(assigns) do
        ~MOB\"\"\"
        <Column gap={12} fill_width={true}>
          {UI.kicker(#{inspect(heading)})}
          <TextField value={@ref} on_change={{self(), :ref}} placeholder="A passage" />
          {UI.pill_button("Count", {self(), :count}, :primary)}
          <Text text={@result} font={:scripture} text_color={:on_surface} />
        </Column>
        \"\"\"
      end
    end
    """
  end

  defp script(key, replies) do
    {:ok, llm} = FakeLLM.start(replies)
    Application.put_env(:bezalel, key, llm: {FakeLLM, llm}, retry_base_ms: 1)
  end

  # The model writes `source` to word_frequency.ex, proposes it, then says `closing`.
  defp builds(source, closing \\ "It counts a passage's words.") do
    script(Builder, [
      [
        {:tool_call, "w1", "dyn_write", %{"path" => "word_frequency.ex", "content" => source}}
      ],
      [{:tool_call, "p1", "dyn_propose", %{"rationale" => "Adds a word-frequency card"}}],
      [{:text, closing}]
    ])
  end

  defp build(view, desc) do
    view
    |> render_info({:tap, {:tab, :workshop}})
    |> render_info({:change, :desc, desc})
    |> render_info({:tap, {:workshop, :build}})
    |> render_async(60_000)
  end

  defp approve(view) do
    view
    |> render_info({:tap, {:workshop, :review_approve}})
    |> render_info({:tap, {:workshop, :approve}})
  end

  # Approves generation `n` as the Workshop does after its sheet.
  defp approve!(n) do
    {:ok, {:review, review}} = Workshop.review(n, %{description: "A word-frequency card"})
    assert {:ok, tools} = Workshop.approve(review)
    tools
  end

  # The open panel's host painted.
  defp painted(view) do
    receive do
      {Host, _pid, {:view, _tree}} = message -> render_info(view, message)
    after
      5_000 -> flunk("the tool's screen didn't paint")
    end
  end

  defp host(view), do: assigns(view).tool_host.pid

  # Feeds the study loop's events to the screen until its run ends.
  defp until_done(view) do
    receive do
      {:rho, _session, event} = message ->
        view = render_info(view, message)
        if match?(%{type: :agent_end}, event), do: view, else: until_done(view)
    after
      5_000 -> flunk("the loop went quiet")
    end
  end

  defp ask(view, text) do
    view
    |> render_info({:tap, {:tab, :study}})
    |> render_info({:change, :draft, text})
    |> render_info({:tap, {:study, :send}})
    |> until_done()
  end

  defp offered(request), do: Enum.map(request.tools, & &1.name)

  # Drops the model calls made so far (a build's).
  defp flush_requests do
    receive do
      {:llm_request, _} -> flush_requests()
    after
      0 -> :ok
    end
  end

  test "a live build writes a tool and its screen; nothing runs until approved; then the panel draws it and the study agent calls it" do
    builds(word_frequency())
    view = AppScreen |> mount_screen() |> render_info({:tap, {:tab, :workshop}})
    assert Workshop.mode(assigns(view).account) == :live
    assert text(view) =~ "Build with"

    view = build(view, "A word-frequency card for a passage")

    # The model was asked to build what was described, with the Dyn rules.
    assert_received {:llm_request, first}
    assert hd(first.messages).content |> hd() |> Map.get(:text) =~ "word-frequency card"
    assert first.system_prompt =~ "Bezalel.Workshop.Study"
    assert "dyn_propose" in offered(first)

    # What it will add, before anything runs.
    assert {:review, review} = assigns(view).build

    assert [%{title: "Word Frequency", tool: "word_frequency", screen: "WordFrequency.Screen"}] =
             review.changes

    assert Enum.all?(review.selftests, & &1.ok)
    assert text(view) =~ "READY FOR YOUR APPROVAL"
    assert text(view) =~ "New tool · word_frequency · with a screen"
    assert text(view) =~ "It counts a passage's words."
    assert Rho.Dyn.tools() == []
    assert Library.list_tools() == []

    view = render_info(view, {:tap, {:workshop, :review_approve}})
    assert text(view) =~ "Add Word Frequency to Bezalel?"
    view = render_info(view, {:tap, {:workshop, :approve}})

    # Approved: on probation, on the shelf, its panel open on its screen.
    assert %{status: :probation} = Rho.Dyn.status()
    assert [{"word_frequency", _}] = Rho.Dyn.tools()
    assert [%Tool{kind: "dyn", name: "Word Frequency"} = tool] = Library.list_tools()
    assert %{"tool" => "word_frequency", "screen" => "WordFrequency.Screen"} = tool.data
    assert assigns(view).tab == :tool
    assert Workshop.status(tool) == :probation

    view = painted(view)
    assert text(view) =~ "MOST FREQUENT WORDS"
    assert text(view) =~ "BUILT BY YOU · ON PROBATION"
    send(host(view), {:change, :ref, "Exodus 31:2-3"})
    send(host(view), {:tap, :count})
    view = view |> painted() |> painted()
    assert text(view) =~ "the 3"
    assert_renderable(view)

    # The study agent offers it from its next model call, and runs it.
    flush_requests()

    script(Live, [
      [{:tool_call, "c1", "word_frequency", %{"reference" => "Exodus 31:2-3"}}],
      [{:text, "Counted."}]
    ])

    _view = ask(view, "Which words recur in Exodus 31:2-3?")
    assert_received {:llm_request, study}
    assert "word_frequency" in offered(study)
    refute "dyn_write" in offered(study)
    assert_received {:llm_request, after_tool}
    result = List.last(after_tool.messages)
    assert result.role == :tool
    assert hd(result.content).text =~ "the 3"
  end

  test "the check refuses a call a tool may not make: no proposal, and the Workshop says why" do
    forbidden = """
    defmodule Bezalel.Dyn.Notes do
      @behaviour Rho.Tool
      def name, do: "notes"
      def description, do: "Keeps notes."
      def parameter_schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _ctx), do: {:ok, File.write!("notes.txt", "x")}
      def selftest, do: :ok
    end
    """

    script(Builder, [
      [{:tool_call, "w1", "dyn_write", %{"path" => "notes.ex", "content" => forbidden}}],
      [{:tool_call, "p1", "dyn_propose", %{"rationale" => "Adds notes"}}],
      [{:text, "The check refused File, so I couldn't build it."}]
    ])

    view = AppScreen |> mount_screen() |> build("A notes tool")
    assert {:failed, why} = assigns(view).build
    assert why =~ "No tool was proposed. The model said: The check refused File"
    assert Rho.Dyn.status().pending == nil

    # What the model was told, and what else Bezalel's config keeps out.
    for {call, refused} <- [
          {~s|File.write!("x", "y")|, "File"},
          {"Bezalel.Library.list_tools()", "Bezalel.Library"},
          {~s|Req.get!("https://example.com")|, "Req"},
          {~s|Exqlite.Sqlite3.open("x")|, "Exqlite"},
          {"Mob.State.put(:bezalel_model, 1)", "Mob.State"},
          {~s|:mob_nif.open_url("https://example.com")|, "mob_nif"}
        ] do
      :ok = Rho.Dyn.stage_reset()

      :ok =
        Rho.Dyn.stage_put("x.ex", """
        defmodule Bezalel.Dyn.X do
          def go, do: #{call}
        end
        """)

      assert {:error, %{stage: :check, reason: reason}} = Rho.Dyn.propose("x")
      assert reason =~ refused
    end
  end

  test "Change the tool builds on its generation; a change that crashes on probation is reverted to the version before, and the Workshop says so" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    :ok = Rho.Dyn.subscribe()

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
      |> painted()
      |> render_info({:tap, {:tool, :change}})

    assert assigns(view).tab == :workshop
    assert text(view) =~ "Changing Word Frequency"

    builds(word_frequency(crash: true, heading: "Word counts"), "Changed the heading.")
    view = build(view, "Call the heading Word counts")

    # The model was asked to change this tool, by module and file.
    assert_received {:llm_request, first}
    request = hd(first.messages).content |> hd() |> Map.get(:text)
    assert request =~ "Change the tool Bezalel.Dyn.WordFrequency"
    assert request =~ "word_frequency.ex"
    assert {:review, %{changes: [%{change: :changed}]}} = assigns(view).build
    assert text(view) =~ "Changed · word_frequency · with a screen"

    view = approve(view)
    assert %{generation: 2, parent: 1, status: :probation} = Rho.Dyn.status()
    assert [%Tool{id: id, data: %{"generation" => 2}}] = Library.list_tools()
    assert id == tool.id
    view = painted(view)
    assert text(view) =~ "WORD COUNTS"

    # The study agent calls the changed tool three times; it crashes each time.
    boom = %{"reference" => "boom"}

    script(Live, [
      [
        {:tool_call, "c1", "word_frequency", boom},
        {:tool_call, "c2", "word_frequency", boom},
        {:tool_call, "c3", "word_frequency", boom}
      ],
      [{:text, "It crashed."}]
    ])

    view = ask(view, "Count boom")
    reverted = Dyn.await(:reverted)
    assert %{from: 2, to: 1} = reverted
    view = render_info(view, {:rho_dyn, reverted})

    assert assigns(view).toast.text =~
             "Word Frequency crashed (3 crashes within 60 s on probation)"

    # The version before runs again, the shelf shows it (the request it was
    # built from, its generation), and the panel says what happened.
    assert %{generation: 1} = Rho.Dyn.status()
    shelved = Library.get_tool(tool.id)
    assert {:change_reverted, _why} = Workshop.status(shelved)
    assert %{description: "A word-frequency card", data: %{"generation" => 1}} = shelved
    view = render_info(view, {:tap, {:workshop, {:open_tool, tool.id}}}) |> painted()
    assert text(view) =~ "Your last change to this tool crashed while it was on probation"
    assert text(view) =~ "MOST FREQUENT WORDS"
    assert text(view) =~ "A word-frequency card"
    refute text(view) =~ "Call the heading Word counts"
  end

  test "a screen that crashes in the panel says so, and the crash counts against its generation" do
    [tool] =
      word_frequency(crash: true)
      |> then(&Dyn.propose!(%{"word_frequency.ex" => &1}))
      |> approve!()

    view = AppScreen |> mount_screen() |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    view = painted(view)
    %{pid: pid, ref: ref} = assigns(view).tool_host
    send(pid, {:tap, :boom})
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    view = render_info(view, {:DOWN, ref, :process, pid, reason})

    assert {:crashed, why} = assigns(view).tool_view
    assert why =~ "screen boom"
    assert text(view) =~ "IT STOPPED WITH AN ERROR"
    assert %{type: :crash, gen: 1} = Dyn.await(:crash)

    view = view |> render_info({:tap, {:tool, :reopen}}) |> painted()
    assert text(view) =~ "MOST FREQUENT WORDS"
    # Leaving the panel stops its host, as an orderly exit.
    host = host(view)
    ref = Process.monitor(host)
    _view = render_info(view, {:tap, {:tab, :study}})
    assert_receive {:DOWN, ^ref, :process, ^host, :normal}, 5_000
  end

  test "an approved tool is still there after the app restarts" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    assert %{generation: 1, mode: :normal, reverted: nil} = Dyn.relaunch()

    assert [{"word_frequency", _}] = Rho.Dyn.tools()
    assert Workshop.status(tool) in [:probation, :running]

    view = AppScreen |> mount_screen() |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    assert text(painted(view)) =~ "MOST FREQUENT WORDS"
  end

  test "Remove proposes a generation without the tool; approved, it and its shelf entry are gone" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()

    view =
      AppScreen
      |> mount_screen()
      |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
      |> render_info({:tap, {:tool, :remove}})

    assert assigns(view).tab == :workshop

    assert {:review, %{changes: [%{change: :removed, title: "Word Frequency"}]}} =
             assigns(view).build

    # Still there until approved.
    assert [{"word_frequency", _}] = Rho.Dyn.tools()

    view = render_info(view, {:tap, {:workshop, :review_approve}})
    assert text(view) =~ "Remove Word Frequency?"
    view = render_info(view, {:tap, {:workshop, :approve}})

    assert Rho.Dyn.tools() == []
    assert Library.list_tools() == []
    assert assigns(view).toast.text =~ "Removes Word Frequency"
  end

  # Approves a Remove of `tool` from its panel; it leaves the shelf.
  defp remove!(tool) do
    AppScreen
    |> mount_screen()
    |> render_info({:tap, {:workshop, {:open_tool, tool.id}}})
    |> painted()
    |> render_info({:tap, {:tool, :remove}})
    |> approve()

    assert :error = Rho.Dyn.lookup({:tool, tool.data["tool"]})
    refute Enum.any?(Library.list_tools(), &(&1.id == tool.id))
  end

  test "a Remove reverted at the next boot (its launch died) puts the tool back on the shelf" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    remove!(tool)

    assert %{reverted: %{from: 2, to: 1}} = Dyn.relaunch_after_crash()
    assert [{"word_frequency", _}] = Rho.Dyn.tools()
    # What the app does at start (Bezalel.App.on_start).
    :ok = Workshop.reconcile()

    assert [%Tool{id: id, description: "A word-frequency card"} = back] = Library.list_tools()
    assert id == tool.id
    assert %{"generation" => 1, "removed" => false, "tool" => "word_frequency"} = back.data
    assert {:removal_reverted, why} = Workshop.status(back)
    assert why =~ "never reached stable"

    view = AppScreen |> mount_screen() |> render_info({:tap, {:workshop, {:open_tool, id}}})
    view = painted(view)
    assert text(view) =~ "MOST FREQUENT WORDS"
    assert text(view) =~ "Removing this tool was undone"
  end

  test "a Remove reverted on probation puts the tool back on the shelf, and the toast says so" do
    boom = """
    defmodule Bezalel.Dyn.Boom do
      @behaviour Rho.Tool
      def name, do: "boom"
      def description, do: "Crashes."
      def parameter_schema, do: %{"type" => "object", "properties" => %{}}
      def run(_args, _ctx), do: raise("boom")
      def selftest, do: :ok
    end
    """

    tools =
      %{"word_frequency.ex" => word_frequency(), "boom.ex" => boom}
      |> Dyn.propose!()
      |> approve!()

    tool = Enum.find(tools, &(&1.name == "Word Frequency"))
    remove!(tool)
    :ok = Rho.Dyn.subscribe()

    # The generation without it crashes on probation: another tool in it does.
    script(Live, [
      [
        {:tool_call, "c1", "boom", %{}},
        {:tool_call, "c2", "boom", %{}},
        {:tool_call, "c3", "boom", %{}}
      ],
      [{:text, "It crashed."}]
    ])

    view = AppScreen |> mount_screen() |> ask("Crash it")
    assert %{from: 2, to: 1} = reverted = Dyn.await(:reverted)
    view = view |> render_info({:rho_dyn, reverted}) |> render_info({:tap, {:tab, :workshop}})

    assert assigns(view).toast.text =~ "Bezalel without Word Frequency crashed"
    back = Library.get_tool(tool.id)
    assert %{data: %{"generation" => 1, "removed" => false}} = back
    assert {:removal_reverted, _} = Workshop.status(back)
    assert text(view) =~ "Back: removing it was undone"
  end

  test "a tool that runs with no shelf entry gets one; a removal that runs keeps it off" do
    [tool] = word_frequency() |> then(&Dyn.propose!(%{"word_frequency.ex" => &1})) |> approve!()
    :ok = Library.delete_tool(tool)
    :ok = Workshop.reconcile()

    assert [%Tool{name: "Word Frequency", description: "test change"} = back] =
             Library.list_tools()

    assert %{"module" => "Bezalel.Dyn.WordFrequency", "generation" => 1} = back.data

    remove!(back)
    :ok = Workshop.reconcile()
    assert Library.list_tools() == []
  end

  test "the example in the guide the model reads passes the check, compiles and selftests" do
    guide = Prompt.dyn_guide()
    [_, example] = String.split(guide, "A small complete example (`verse_card.ex`):\n")

    source =
      example
      |> String.split("\n")
      |> Enum.map_join("\n", &String.replace_prefix(&1, "    ", ""))

    n = Dyn.propose!(%{"verse_card.ex" => source})
    [tool] = approve!(n)
    assert %{name: "Verse Card", data: %{"screen" => "VerseCard.Screen"}} = tool
    {:ok, module} = Rho.Dyn.lookup({:tool, "verse_card"})
    assert {:ok, text} = module.run(%{"reference" => "Exodus 31:2"}, %{})
    assert text =~ "Exodus 31:2"
  end
end
