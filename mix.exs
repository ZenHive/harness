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
      listeners: [Phoenix.CodeReloader],
      name: "Harness",
      description:
        "OTP-native AI agent orchestrator: dispatches rmap tasks to headless coding agents in isolated worktrees, verifies with the target project's own check stack, and reports verified outcomes.",
      source_url: "https://github.com/efries/harness",
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: test_coverage()
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
      extras: ["README.md", "CHANGELOG.md", "ROADMAP.md"],
      # Internal modules (@moduledoc false) named in CHANGELOG/doc prose —
      # legitimate mentions, but ExDoc warns on autolinks to hidden modules.
      skip_code_autolink_to: ["Harness.Application", "Harness.Worktree.Sweeper"]
    ]
  end

  # Coverage excludes only genuinely-untestable surfaces, so the
  # --cover-threshold gate reflects the testable code (not metric-gaming):
  #   * Phoenix-generated boilerplate (Endpoint/Router/Layouts/Tokens/Repo/
  #     QueueBootstrap) — no branch logic to assert.
  #   * Chat.Claude — `claude -p` Port orchestration (spawns a real external
  #     binary; integration territory). Its pure logic lives in
  #     Chat.Claude.StreamParser, which IS covered.
  # The dashboard LiveViews are NOT excluded — they're exercised via
  # Phoenix.LiveViewTest (test/harness/dashboard/{live,chat_live}_test.exs).
  defp test_coverage do
    [
      ignore_modules: [
        Harness.Dashboard.Endpoint,
        Harness.Dashboard.Router,
        Harness.Dashboard.Router.Helpers,
        Harness.Dashboard.Layouts,
        Harness.Dashboard.Tokens,
        Harness.Repo,
        Harness.Oban.QueueBootstrap,
        Harness.Chat.Claude,
        # Task 140: Postgres chat persistence — exercised by :integration tests.
        Harness.Chat.Store.Postgres,
        Harness.Chat.Store.Postgres.ChatSession
      ]
    ]
  end

  defp dialyzer do
    [
      # OOM mitigation: skip transitive deps (default is :app_tree).
      # Tidewave/bandit's HTTP stack (plug, finch, mint, gun, cowlib, etc.)
      # is not in lib/ call graph and bloats PLT.
      plt_add_deps: :apps_direct,
      # `:jason` is transitive via dev/test-only tooling (`credo`, `dialyzer_json`,
      # `ex_unit_json`); `:apps_direct` excludes it, so direct runtime use of
      # `Jason.*` in `lib/` (Task 43: verification baseline filter) needs an
      # explicit add to keep dialyzer aware of the function signatures.
      # `:ecto` / `:db_connection` are transitive via `ecto_sql` / `postgrex`
      # (Task 48: Oban-backed dispatch); `:apps_direct` excludes them, so
      # `use Ecto.Repo` in `lib/harness/repo.ex` needs them explicitly added.
      # `:peri` is transitive via `anubis_mcp` (Task 79: MCP server); its
      # `@spec`s reference `Peri.Error.t/0`, so `:apps_direct` excluding it
      # surfaces `unknown_type` warnings on anubis's compiled code.
      plt_add_apps: [
        :mix,
        :jason,
        :peri,
        :ecto,
        :db_connection,
        :phoenix,
        :phoenix_live_view,
        :phoenix_pubsub,
        :phoenix_template,
        :phoenix_html,
        :oban_web,
        :plug
      ],
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # Core
      {:descripex, "~> 0.7"},
      # Compile-time option-schema validation for the Harness.Dispatch.RunTool macro DSL.
      {:nimble_options, "~> 1.0"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:oban, "~> 2.22"},
      {:req, "~> 0.5"},
      {:anubis_mcp, "~> 1.6"},

      # Dashboard (Task 50) — Phoenix LiveView + embedded Oban Web. Bandit is
      # optional so mountable consumers with their own Phoenix endpoint do not
      # get a second HTTP server forced into their supervision tree; the
      # standalone Harness.Dashboard.Endpoint guards its Bandit reference with
      # `Code.ensure_loaded?(Bandit)` and falls back with a clear log message.
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_pubsub, "~> 2.2"},
      {:phoenix_html, "~> 4.2"},
      {:oban_web, "~> 2.12"},
      {:bandit, "~> 1.11", optional: true},

      # Dev/test tooling — standard harness stack per global conventions
      # lazy_html: LiveView 1.x's DOM parser for Phoenix.LiveViewTest assertions.
      {:lazy_html, ">= 0.1.0", only: :test},
      {:ex_unit_json, "~> 0.5.0", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:ex_ast, "~> 0.12", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:boxart, "~> 0.3.3", only: [:dev, :test], runtime: false},

      # Tidewave (dev MCP + HTTP server for agent interface)
      {:tidewave, "~> 0.5", only: :dev}
    ]
  end

  defp aliases do
    [
      # See ~/.claude/includes/elixir-setup.md § Standard Aliases for the three-tier model.
      # TagTODO/TagFIXME stay on in .credo.exs for visibility (`mix credo` shows them);
      # gate excludes them so the alias fails only on real regressions, not tracked debt.
      "check.fast": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME"
      ],
      # Hook-bound (180s). Dialyzer lives in `precommit.full` — on a cold PLT it
      # blows the marketplace pre-commit hook's 180s timeout and gets killed
      # mid-run, denying the commit with no clean error.
      # Threshold 80 (vs the 85 project default) reflects the offline-only suite:
      # the Phase 7 Postgres/Oban layer (Repo, QueueBootstrap, Run.Worker, Oban)
      # is exercised by :integration tests that require a live DB — re-include
      # them and re-raise the threshold once those tests run in CI.
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME",
        "doctor --raise",
        # preferred_envs (cli/0) is ignored for alias steps — set MIX_ENV
        # explicitly. `mix cmd` execs its first token directly (no shell), so an
        # inline `MIX_ENV=test` prefix is read as the program name (:enoent);
        # route through `sh -c` so the env assignment is interpreted.
        ~s|cmd sh -c "MIX_ENV=test mix test.json --quiet --cover --cover-threshold 80 --summary-only --exclude integration"|,
        "sobelow --exit --skip"
      ],
      # CI mirror — adds dialyzer. Matches .github/workflows/harness.yml.
      # Run before handing off to a reviewer / opening a PR.
      "precommit.full": ["precommit", "dialyzer.json --quiet"],
      "sobelow.baseline": ["sobelow --mark-skip-all"]
    ]
  end
end
