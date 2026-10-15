defmodule Bezalel.SettingsTest do
  use Mob.ScreenCase
  @moduletag :screen

  alias Bezalel.AppScreen
  alias Bezalel.Test.{Browser, MemoryStore}

  @openai_key "sk-proj-abcdefghijklmnop1234WXYZ"

  setup do
    MemoryStore.clear()
    Mob.State.delete(:bezalel_model)
    File.rm(Path.join(Rho.Config.data_dir(), "usage.json"))
    :ok
  end

  defp settings, do: AppScreen |> mount_screen() |> render_info({:tap, {:tab, :settings}})

  defp model_ids(view) do
    view = render_info(view, {:tap, {:settings, :models}})

    view
    |> find_all(:box)
    |> Enum.flat_map(fn
      %{props: %{on_tap: {_, {:model, id}}}} -> [id]
      _ -> []
    end)
  end

  describe "subscriptions" do
    test "signed out, each subscription offers a browser sign-in" do
      view = settings()
      assert text(view) =~ "Pro or Max subscription"
      assert text(view) =~ "Plus or Pro subscription"
      refute text(view) =~ "Not built yet"
      assert_renderable(view)
    end

    test "Sign in opens the provider's authorize page; Claude's takes a pasted code" do
      view = settings()

      view = render_info(view, {:tap, {:settings, {:sign_in, :openai_codex}}})
      assert Browser.last() =~ ~r{^https://auth\.openai\.com/oauth/authorize\?}
      assert text(view) =~ "Finish in the browser; it returns here."

      view = render_info(view, {:tap, {:settings, {:sign_in, :anthropic}}})
      assert Browser.last() =~ ~r{^https://claude\.ai/oauth/authorize\?}
      assert assigns(view).login == :anthropic
      assert find(view, :text_field, placeholder: "Paste the code")

      # A code from another sign-in (its state doesn't match) is refused,
      # and the flow stays open for the right one.
      view = render_info(view, {:change, {:settings, :login_code}, "the-code#not-this-flow"})
      view = render_info(view, {:tap, {:settings, :paste_code}})
      assert assigns(view).toast.text =~ "from another sign-in"
      assert assigns(view).login == :anthropic
    end

    test "a finished sign-in shows the account; Sign out forgets it" do
      view = settings()

      :ok =
        Rho.Auth.put(:anthropic, %{
          "type" => "oauth",
          "access" => "access-token",
          "refresh" => "refresh-token",
          "expires" => System.os_time(:millisecond) + 3_600_000,
          "email" => "pastor@example.org"
        })

      view = render_info(view, {:rho_login, :anthropic, :ok})
      assert text(view) =~ "pastor@example.org"
      assert text(view) =~ "Claude · signed in through the browser"
      assert assigns(view).toast.text == "Signed in to Claude."

      view = render_info(view, {:tap, {:settings, {:sign_out, :anthropic}}})
      refute text(view) =~ "pastor@example.org"
      assert MemoryStore.get("auth:anthropic") == :error
    end

    test "a failed sign-in says why" do
      view = settings()
      view = render_info(view, {:tap, {:settings, {:sign_in, :anthropic}}})
      view = render_info(view, {:rho_login, :anthropic, {:error, "Claude said no (denied)"}})
      assert assigns(view).toast.text == "Sign-in failed: Claude said no (denied)"
      assert assigns(view).login == nil
      refute find(view, :text_field, placeholder: "Paste the code")
    end
  end

  describe "API keys" do
    test "a saved key is stored, shown masked, survives a restart and can be removed" do
      view = settings()
      view = render_info(view, {:change, {:settings, {:key, :openai}}, "  #{@openai_key}\n"})
      view = render_info(view, {:tap, {:settings, {:save_key, :openai}}})

      assert {:ok, json} = MemoryStore.get("auth:openai")
      assert Jason.decode!(json) == %{"type" => "api_key", "key" => @openai_key}
      assert assigns(view).toast.text == "OpenAI key saved."
      assert text(view) =~ "sk-pro…WXYZ"
      refute text(view) =~ @openai_key
      refute inspect(assigns(view).account) =~ @openai_key

      # A fresh mount (the app restarted) reads it back from the store.
      view = settings()
      assert text(view) =~ "sk-pro…WXYZ"

      view = render_info(view, {:tap, {:settings, {:remove_key, :openai}}})
      assert MemoryStore.get("auth:openai") == :error
      refute text(view) =~ "sk-pro…WXYZ"
      assert find(view, :text_field, placeholder: "Paste your key", secure: true)
    end

    test "with an Anthropic key, Claude's sign-in says it replaces the key" do
      :ok = Rho.Auth.put_api_key(:anthropic, "sk-ant-api03-abcdefghijklmnop")
      assert text(settings()) =~ "Signing in replaces your Anthropic key"
    end

    test "saving an empty key asks for one and stores nothing" do
      view = settings()
      view = render_info(view, {:change, {:settings, {:key, :google}}, "   "})
      view = render_info(view, {:tap, {:settings, {:save_key, :google}}})
      assert assigns(view).toast.text == "Paste your Google Gemini key first."
      assert MemoryStore.get("auth:google") == :error
    end
  end

  describe "models" do
    test "the model list follows the credentials" do
      view = settings()
      assert model_ids(view) == []
      view = render_info(view, {:tap, {:settings, :models}})
      assert text(view) =~ "No models yet."
      # The default is Claude; without access it says what it needs.
      view = render_info(view, {:tap, :sheet})
      assert text(view) =~ "Needs your Claude sign-in or Anthropic API key"

      view =
        render_info(
          view,
          {:change, {:settings, {:key, :google}}, "AIzaSyFakeButWellFormedKey0123"}
        )

      view = render_info(view, {:tap, {:settings, {:save_key, :google}}})
      ids = model_ids(view)
      assert ids != []
      assert Enum.all?(ids, &String.starts_with?(&1, "google:"))

      sheet = render_info(view, {:tap, {:settings, :models}})
      assert text(sheet) =~ "GEMINI (GOOGLE)"
      assert text(sheet) =~ "Gemini API key"
      assert text(sheet) =~ "IMAGES"
      assert_renderable(sheet)

      # The pick persists, and Settings names it.
      [id | _] = ids
      view = render_info(sheet, {:tap, {:model, id}})
      assert Bezalel.Settings.model() == id
      assert text(view) =~ Bezalel.Models.get(id).name
      assert text(view) =~ "Gemini (Google)"

      view = render_info(view, {:tap, {:settings, {:remove_key, :google}}})
      assert model_ids(view) == []
    end
  end

  describe "token usage" do
    test "zero before any model call" do
      assert text(settings()) =~ "0 tokens"
    end

    test "today and total per model, from rho's usage" do
      today = Date.to_iso8601(Rho.Budget.today())
      counters = fn input, output -> %{"requests" => 1, "input" => input, "output" => output} end

      usage = %{
        "days" => %{today => %{"anthropic:claude-haiku-4-5-20251001" => counters.(800, 400)}},
        "total" => %{
          "anthropic:claude-haiku-4-5-20251001" => counters.(9_000, 3_400),
          "google:gemini-3.5-flash" => counters.(300, 200),
          # An alias of the catalog's dated id (counted with it), and a model
          # the catalog no longer lists (shown by its spec).
          "anthropic:claude-haiku-4-5" => counters.(50, 50),
          "anthropic:claude-2" => counters.(10, 0)
        }
      }

      File.write!(Path.join(Rho.Config.data_dir(), "usage.json"), Jason.encode!(usage))
      view = settings() |> render_info({:rho_usage, :changed})
      t = text(view)

      assert t =~ "13k tokens across 3 models"
      assert t =~ "1.2k today"
      assert t =~ "Claude Haiku 4.5 1.2k today · 12.5k"
      assert t =~ "Gemini 3.5 Flash 0 today · 500"
      assert t =~ "anthropic:claude-2 0 today · 10"
      [_, usage] = String.split(t, "TOKEN USAGE")
      refute usage =~ "Sonnet"
      assert_renderable(view)
    end
  end
end
