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
      {:mob_bezalel, path: "../mob_bezalel"},
      {:ecto_sqlite3, "~> 0.18"},
      # The agent core: models, sign-in, usage. A path dep while rho and
      # Bezalel move together; it moves to Hex once rho is published.
      {:rho, path: "../rho"},
      # The platform secure store (Keychain / Keystore) rho keeps the
      # sign-ins and API keys in. Unreleased: a path dep until it's on Hex.
      {:mob_secure_store, path: "../mob_secure_store"},
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
end
