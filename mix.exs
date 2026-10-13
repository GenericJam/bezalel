defmodule Bezalel.MixProject do
  use Mix.Project

  def project do
    [
      app: :bezalel,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      deps: deps(),
      aliases: aliases(),
      erlc_paths: ["src"],
      erlc_options: [:debug_info]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:mob,     "~> 0.9.17"},
      mob_dev_dep(),
      # The design plugin (style package): Bezalel's themes, palette, fonts.
      {:mob_bezalel, path: "../mob_bezalel"},
      {:ecto_sqlite3, "~> 0.18"},
      # Code quality — Credo + ex_slop (catches AI-generated patterns
      # like blanket rescue, narrator docs, redundant Enum chains, etc).
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4.2", only: [:dev, :test], runtime: false}
    ]
  end

  # Style packages that ship fonts need a mob_dev that bundles a style's
  # `assets.fonts`; MOB_DEV_PATH points at a local checkout until that's on Hex.
  defp mob_dev_dep do
    case System.get_env("MOB_DEV_PATH") do
      nil -> {:mob_dev, "~> 0.7.12", only: :dev, runtime: false}
      path -> {:mob_dev, path: path, only: :dev, runtime: false, override: true}
    end
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
