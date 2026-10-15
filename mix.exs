defmodule Bezalel.MixProject do
  use Mix.Project

  def project do
    [
      app: :bezalel,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      # 0.9.18+: the light/dark watcher follows the OS (MOB-479) and
      # <Scroll anchor="bottom"> renders on iOS (MOB-481).
      {:mob, "~> 0.9.18"},
      # 0.7.25+: bundles a style package's fonts (mob_bezalel's) in dev and
      # release builds (MOB-476, MOB-480).
      {:mob_dev, "~> 0.7.25", only: :dev, runtime: false},
      # The design plugin (style package): Bezalel's themes, palette, fonts.
      sibling(:mob_bezalel, "GenericJam/mob_bezalel", "9dbf917e9f86ee81d997b85f225ef2209c741c17"),
      {:ecto_sqlite3, "~> 0.18"},
      # The study packs are read with Exqlite directly (Bezalel.Study.DB).
      {:exqlite, "~> 0.42"},
      # The agent core: models, sign-in, usage. Pinned to a commit until rho
      # is on Hex.
      sibling(:rho, "GenericJam/rho", "f07e8e778d2d28dacdf4c6beff74cd6624f5e144"),
      # The platform secure store (Keychain / Keystore) rho keeps the
      # sign-ins and API keys in. Unreleased: pinned to a commit.
      sibling(
        :mob_secure_store,
        "GenericJam/mob_secure_store",
        "99a94bcbdfb4ed6f57c2286e994f885488e5886a"
      ),
      # The CA bundle Bezalel.Certs loads (phones have none OTP can find).
      {:castore, "~> 1.0"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false},
      # `mix mob.icon` (design/icon/ → platform icons).
      {:image, "~> 0.54", only: :dev, runtime: false}
    ]
  end

  # Shorthands for the common mob workflows — `mix deploy` is `mix mob.deploy`,
  # etc. Extra args pass through to the underlying task, so `mix deploy
  # --device <udid>` works as expected.
  defp aliases do
    [
      connect: ["mob.connect"],
      deploy: ["mob.deploy"],
      watch: ["mob.watch"],
      icon: ["mob.icon"],
      ios: ["mob.deploy --ios"],
      "ios.native": ["mob.deploy --native --ios"],
      android: ["mob.deploy --android"],
      "android.native": ["mob.deploy --native --android"]
    ]
  end

  # A dependency developed alongside Bezalel: GitHub, pinned to a commit, so
  # a fresh clone builds. BEZALEL_LOCAL_DEPS=1 uses the sibling checkouts
  # (../rho, ../mob_secure_store, ../mob_bezalel) instead, for working on them.
  defp sibling(app, repo, ref) do
    if System.get_env("BEZALEL_LOCAL_DEPS") in ["1", "true"],
      do: {app, path: "../#{app}", override: true},
      else: {app, github: repo, ref: ref}
  end
end
