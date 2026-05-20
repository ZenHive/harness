defmodule Harness.MixProject do
  use Mix.Project

  def project do
    [
      app: :harness,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Harness",
      description:
        "OTP-native AI agent orchestrator: dispatches rmap tasks to headless coding agents in isolated worktrees, verifies with the target project's own check stack, and reports verified outcomes.",
      source_url: "https://github.com/efries/harness",
      docs: docs(),
      dialyzer: dialyzer()
    ]
  end

  # preferred_envs for ex_unit_json / dialyzer_json — Mix doesn't inherit them from deps.
  def cli do
    [preferred_envs: ["test.json": :test, "dialyzer.json": :dev]]
  end

  # test/support holds test-only scaffolding (fixtures) — compiled in :test only.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {Harness.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp docs do
    [
      main: "Harness",
      extras: ["README.md", "CHANGELOG.md", "ROADMAP.md"]
    ]
  end

  defp dialyzer do
    [
      # OOM mitigation: skip transitive deps (default is :app_tree).
      # Tidewave/bandit's HTTP stack (plug, finch, mint, gun, cowlib, etc.)
      # is not in lib/ call graph and bloats PLT.
      plt_add_deps: :apps_direct,
      plt_add_apps: [:mix],
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core
      {:descripex, "~> 0.6"},

      # Dev/test tooling — standard harness stack per global conventions
      {:ex_unit_json, "~> 0.4.3", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.5", only: [:dev, :test], runtime: false},
      {:boxart, "~> 0.3.3", only: [:dev, :test], runtime: false},

      # Tidewave (dev MCP + HTTP server for agent interface)
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.11", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4016) end)'"
      ]
    ]
  end
end
