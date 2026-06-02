defmodule Harness.CheckStack.Preset.Elixir do
  @moduledoc """
  The standard Elixir mix-based verification check stacks.

  Two stacks ship here, deliberately distinct:

    * `preset/0` (`:elixir`) — the lighter day-to-day grading stack. Five
      checks, in the order they run: `test`, `dialyzer`, `credo`, `doctor`,
      `sobelow`. `test` runs first so later checks reuse the `_build` it
      produces. Each command carries the flags that make its exit status a
      reliable pass/fail signal.

    * `precommit/1` (`:elixir_precommit`) — the **mergeable-bar** stack, mirroring
      a project's `mix precommit` / CI gate. It adds the three gates whose
      absence lets a green `preset/0` verdict diverge from an actually-mergeable
      change: `format --check-formatted`, `compile --warnings-as-errors`, and a
      coverage threshold on `test`. This is the stack to register a project
      against when "harness graded it green" must imply "the project's own merge
      gate would pass too" (Task 97 — a `preset/0`-green run that fails
      `mix precommit`'s coverage gate is unmergeable but looks done).

  This module owns the canonical Elixir check lists;
  `Harness.Verification.elixir_preset/0` delegates to `preset/0` for back-compat.
  """

  alias Harness.CheckStack
  alias Harness.Verification.Check

  @credo_check %Check{name: "credo", command: "mix", args: ["credo", "--strict"]}

  @sobelow_check %Check{name: "sobelow", command: "mix", args: ["sobelow", "--exit", "--skip"]}

  # Setup runs twice per run lifecycle: at worktree-provision time (before the
  # agent spawns — `Harness.Verification.prepare/2`) and again ahead of the
  # verification checks. `deps.compile` is here for the provision pass: a fresh
  # worktree's first mix command otherwise compiles every dep silently for
  # minutes, which trips the agent driver's idle/progress reflex. On the
  # verification pass both steps are fast no-ops against the warmed _build.
  @setup [
    %Check{name: "deps", command: "mix", args: ["deps.get"]},
    %Check{name: "deps.compile", command: "mix", args: ["deps.compile"]}
  ]

  @postgres_test_env %{"MIX_ENV" => "test", "HARNESS_DB_NAME" => {:harness, :test_database}}
  @postgres_setup [
    %Check{name: "test-db-create", command: "mix", args: ["ecto.create", "--quiet"], env: @postgres_test_env},
    %Check{name: "test-db-migrate", command: "mix", args: ["ecto.migrate", "--quiet"], env: @postgres_test_env}
  ]

  @checks [
    %Check{name: "test", command: "mix", args: ["test.json"]},
    %Check{name: "dialyzer", command: "mix", args: ["dialyzer.json"]},
    @credo_check,
    %Check{name: "doctor", command: "mix", args: ["doctor"]},
    @sobelow_check
  ]

  @default_cover_threshold 80

  @doc """
  Returns the Elixir preset as a `%Harness.CheckStack{}`.

  `timeout_per_check` is left `nil` — the verification runner's default of
  10 minutes already accommodates a cold-PLT dialyzer run on this codebase.
  """
  @spec preset() :: CheckStack.t()
  def preset, do: %CheckStack{name: :elixir, setup: @setup, checks: @checks}

  @doc """
  Returns the mergeable-bar Elixir stack as a `%Harness.CheckStack{}` named
  `:elixir_precommit`.

  Mirrors the canonical `mix precommit` / CI gate so a green verdict implies a
  mergeable change. On top of `preset/0`'s tools it adds `format
  --check-formatted`, `compile --warnings-as-errors`, and a coverage threshold
  on `test`, and runs `doctor --raise` so doctor's exit status actually gates.

  ## Options

    * `:cover_threshold` — minimum line-coverage percent the `test` check
      enforces via `mix test.json --cover --cover-threshold`. A run below it
      reds the verdict, exactly as the project's merge gate would. Defaults to
      `#{@default_cover_threshold}`.
    * `:exclude` — ExUnit tags excluded from the coverage-gated run, e.g.
      `[:integration]` for a suite whose integration tests need a live DB (and
      so can't run in a fresh worktree). Each becomes a `--exclude <tag>` pair.
      Defaults to `[]`.
    * `:include` — ExUnit tags the coverage-gated run should include, e.g.
      `[:integration]` when the project's verification environment can satisfy
      those tests. Each becomes a `--include <tag>` pair. Defaults to `[]`.
    * `:database` — set to `:postgres` to provision an isolated test database
      (`mix ecto.create --quiet` then `mix ecto.migrate --quiet`) before checks.
      The setup and test check run with `MIX_ENV=test` and a per-worktree
      `HARNESS_DB_NAME`, leaving the host's default test DB untouched.

  The check order warms `_build` for the later tools: `format` (cheap, fail
  fast), `compile`, `test`, `dialyzer`, `credo`, `doctor`, `sobelow`.
  """
  @spec precommit(keyword()) :: CheckStack.t()
  def precommit(opts \\ []) do
    threshold = Keyword.get(opts, :cover_threshold, @default_cover_threshold)
    exclude = Keyword.get(opts, :exclude, [])
    include = Keyword.get(opts, :include, [])
    database = Keyword.get(opts, :database)

    %CheckStack{
      name: :elixir_precommit,
      setup: precommit_setup(database),
      checks: precommit_checks(threshold, exclude, include, database)
    }
  end

  @spec precommit_setup(:postgres | nil) :: [Check.t()]
  defp precommit_setup(nil), do: @setup
  defp precommit_setup(:postgres), do: @setup ++ @postgres_setup

  @spec precommit_checks(non_neg_integer(), [atom() | String.t()], [atom() | String.t()], :postgres | nil) ::
          [Check.t()]
  defp precommit_checks(threshold, exclude, include, database) do
    [
      %Check{name: "format", command: "mix", args: ["format", "--check-formatted"]},
      %Check{name: "compile", command: "mix", args: ["compile", "--warnings-as-errors"]},
      test_check(test_args(threshold, exclude, include), database),
      %Check{name: "dialyzer", command: "mix", args: ["dialyzer.json"]},
      @credo_check,
      %Check{name: "doctor", command: "mix", args: ["doctor", "--raise"]},
      @sobelow_check
    ]
  end

  @spec test_check([String.t()], :postgres | nil) :: Check.t()
  defp test_check(args, :postgres), do: %Check{name: "test", command: "mix", args: args, env: @postgres_test_env}
  defp test_check(args, nil), do: %Check{name: "test", command: "mix", args: args}

  @spec test_args(non_neg_integer(), [atom() | String.t()], [atom() | String.t()]) :: [String.t()]
  defp test_args(threshold, exclude, include) do
    ["test.json", "--cover", "--cover-threshold", Integer.to_string(threshold)] ++
      Enum.flat_map(exclude, &["--exclude", to_string(&1)]) ++
      Enum.flat_map(include, &["--include", to_string(&1)])
  end
end
