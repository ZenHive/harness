defmodule Harness.AgentAdapter.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/ZenHive/harness_agent_adapter"

  def project do
    [
      app: :harness_agent_adapter,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      name: "Harness.AgentAdapter",
      description:
        "The Harness.AgentAdapter behaviour plus six headless coding-agent CLI adapters " <>
          "(claude, codex, cursor, grok, antigravity, pi), driven uniformly over OTP Ports.",
      source_url: @source_url,
      homepage_url: @source_url,
      docs: docs(),
      dialyzer: dialyzer(),
      package: package()
    ]
  end

  # preferred_envs for ex_unit_json / dialyzer_json — Mix doesn't inherit them
  # from deps. NOTE: preferred_envs is ignored *inside* alias steps (see the
  # `cmd env MIX_ENV=test` steps below) — it only applies when the task name
  # itself is invoked directly (`mix test.json`), not when it appears as one
  # step of another alias.
  def cli do
    [preferred_envs: ["test.json": :test, "dialyzer.json": :dev]]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # No `elixirc_paths/1` override: everything compiles from `lib/`, in every
  # env. The test scaffolding — `Harness.AgentAdapter.Testing.ConformanceCase`
  # and the fixtures/fake adapters it calls — is shipped surface, not test-only:
  # a consumer runs the conformance suite against its own adapter, and a
  # `test/support/` path would never reach that consumer's build.
  defp docs do
    [
      main: "Harness.AgentAdapter",
      extras: ["README.md", "CHANGELOG.md"],
      # AGENTS.md is deliberately NOT an extra: it is a render of CLAUDE.md with
      # its `@~/.claude/includes/*.md` imports inlined, so publishing it would put
      # the operator's global rules on hexdocs. It stays in the repo for the
      # cross-family reviewer, gated by `mix agents.check`, but is not consumer docs.
      source_url: @source_url,
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      description:
        "The Harness.AgentAdapter behaviour plus six headless coding-agent CLI adapters " <>
          "(claude, codex, cursor, grok, antigravity, pi), driven uniformly over OTP Ports.",
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      maintainers: ["ZenHive"],
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp dialyzer do
    [
      # No plt_add_deps/plt_add_apps override: this package's dep stack is small
      # (descripex + jason + dev/test tooling), so the default :app_tree
      # recursion is cheap. harness's `plt_add_deps: :apps_direct` +
      # `plt_add_apps` list was OOM mitigation for its Phoenix/Ecto/Oban stack —
      # irrelevant here; copying it would just drop real deps from the PLT.
      # `lib/harness/agent_adapter/testing/` ships ExUnit-dependent scaffolding
      # (ConformanceCase and the fixtures it calls) so a consumer can run the
      # conformance suite against its own adapter. ExUnit is not an
      # `extra_applications` entry — a consumer's release must not start it —
      # so it has to be added to the PLT explicitly, or every
      # `ExUnit.Callbacks.on_exit/1` / `ExUnit.Assertions.*` call reads as an
      # unknown function.
      plt_add_apps: [:ex_unit],
      plt_local_path: "priv/plts",
      plt_core_path: "priv/plts",
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end

  defp deps do
    [
      # Core
      {:descripex, "~> 0.8"},
      # `Harness.AgentAdapter.Watchdog` calls `Jason.decode/1` in runtime code.
      # In the harness monorepo this was only transitive (via dev/test tooling
      # like credo/dialyzer_json); here it must be a direct runtime dep so a
      # consumer resolving only this package's declared deps still gets it.
      {:jason, "~> 1.0"},

      # Dev/test tooling — vibe_kit baseline (priv/tooling_baseline/elixir.json
      # in the harness repo).
      {:ex_unit_json, "~> 0.6", only: [:dev, :test], runtime: false},
      {:dialyzer_json, "~> 0.2", only: [:dev, :test], runtime: false},
      {:styler, "~> 1.11", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      # ExSlop: Credo plugin flagging AI-generated-code antipatterns (vibe_kit baseline).
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: :dev, runtime: false},
      {:doctor, "~> 0.23", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      # Reach caps ex_ast at ~> 0.12.0 by default; reach uses APIs retained by
      # ex_ast 0.13 (sibling precedent: cartouche, zen_websocket — both pin
      # ex_ast ~> 0.13 with override: true for the same reason).
      {:ex_ast, "~> 0.13", override: true, only: [:dev, :test], runtime: false},
      {:reach, "~> 2.7", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},

      # Tidewave for Claude Code MCP integration (non-Phoenix needs bandit).
      {:tidewave, "~> 0.5", only: :dev},
      {:bandit, "~> 1.11", only: :dev}
    ]
  end

  defp aliases do
    [
      tidewave: [
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4034) end)'"
      ],
      # Fast inner loop. See ~/.claude/includes/elixir-setup.md § Standard
      # Aliases for the three-tier model. TagTODO/TagFIXME stay on in
      # .credo.exs for visibility (`mix credo` shows them); the gate excludes
      # them so the alias fails only on real regressions, not tracked debt.
      "check.fast": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME"
      ],
      # Dispatch-scale gate — the harness reviewer's `check_command` hint.
      "check.dispatch": [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME",
        "doctor --raise",
        "sobelow --skip --exit low"
      ],
      # Fast local pre-commit loop — deliberately WITHOUT dialyzer (cold-PLT
      # cost) or a coverage pass (that's `ci`'s job). Runs the suite plain so
      # a local commit still gets real test signal, just not the coverage gate.
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME",
        "doctor --raise",
        # preferred_envs (cli/0) is ignored for alias steps — set MIX_ENV
        # explicitly. `mix cmd` execs its first token directly (no shell), so an
        # inline `MIX_ENV=test` prefix is read as the program name (:enoent);
        # route through `env` so the assignment is applied before exec.
        "cmd env MIX_ENV=test mix test.json --quiet --summary-only --exclude integration",
        "sobelow --skip --exit low"
      ],
      # Portable gate — every step here runs on a bare clone with nothing but
      # the repo and a BEAM: CI, a fork, a contributor's laptop. Coverage floor
      # 85 matches the vibe_kit family default (a small, single-purpose adapter
      # package with no untestable Phoenix/dashboard surface to exclude).
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict --ignore TagTODO,TagFIXME",
        "doctor --raise",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells",
        # `--exit` is what makes sobelow gate: without it a finding is printed
        # and the task still returns 0. `low` is sobelow's own default for a
        # bare `--exit`, spelled out here to keep it visible.
        "sobelow --skip --exit low",
        "cmd env MIX_ENV=test mix test.json --cover --cover-threshold 85 --exclude integration",
        "dialyzer"
      ],
      # Operator/reviewer gate — `ci` plus the one check that reads this
      # workstation's layout and therefore cannot run on a runner: agents.check
      # re-renders AGENTS.md from CLAUDE.md, which inlines
      # `@~/.claude/includes/*.md` — paths that exist only in the operator's
      # home directory. Never `precommit.full: ["precommit.full"]`-style
      # self-reference — this stays additive over the portable `ci`.
      "precommit.full": ["ci", "agents.check"],
      # Fails when AGENTS.md has drifted from CLAUDE.md. Compares rendered
      # output, not mtimes, so drift in a transitive @-import is caught too.
      # AGENTS.md is what the cross-family (codex/cursor/grok) reviewers read;
      # a stale render makes them gate against rules that already changed.
      "agents.check": [&agents_check/1]
    ]
  end

  # Shells out to a script OUTSIDE this repo, on the developer host: the
  # AGENTS.md renderer needs the claude-marketplace checkout plus
  # ~/.claude/includes. Absent in CI. Skip loudly rather than `mix cmd`'s
  # :enoent, which would abort the whole alias and take every step after it
  # down too.
  @spec agents_check([String.t()]) :: :ok
  defp agents_check(_args) do
    host_script(
      "~/_DATA/code/claude-marketplace/scripts/sync-agents-md.sh",
      ["--check"],
      "AGENTS.md freshness check"
    )
  end

  @spec host_script(String.t(), [String.t()], String.t()) :: :ok
  defp host_script(path, args, label) do
    expanded = Path.expand(path)

    if File.exists?(expanded) do
      {_out, status} =
        System.cmd(expanded, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true)

      if status != 0 do
        Mix.raise("#{label} failed (#{expanded} exited #{status})")
      end
    else
      Mix.shell().info("[skip] #{label}: #{expanded} not found (developer-host script, absent in CI).")
    end

    :ok
  end
end
