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

  The credo check declares a `post_process` hook
  (`Harness.Verification.BaselineFilter.Credo`) so TagTODO findings on TODOs
  inherited from the dispatch base don't red the verdict — dispatched agents
  are graded only on TODOs they introduced.

  This module owns the canonical Elixir check lists;
  `Harness.Verification.elixir_preset/0` delegates to `preset/0` for back-compat.
  """

  alias Harness.CheckStack
  alias Harness.Verification.Check

  @credo_check %Check{
    name: "credo",
    command: "mix",
    args: ["credo", "--strict"],
    post_process: {Harness.Verification.BaselineFilter.Credo, :apply}
  }

  @sobelow_check %Check{name: "sobelow", command: "mix", args: ["sobelow", "--exit", "--skip"]}

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
  def preset, do: %CheckStack{name: :elixir, checks: @checks}

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

  The check order warms `_build` for the later tools: `format` (cheap, fail
  fast), `compile`, `test`, `dialyzer`, `credo`, `doctor`, `sobelow`.
  """
  @spec precommit(keyword()) :: CheckStack.t()
  def precommit(opts \\ []) do
    threshold = Keyword.get(opts, :cover_threshold, @default_cover_threshold)
    exclude = Keyword.get(opts, :exclude, [])

    %CheckStack{name: :elixir_precommit, checks: precommit_checks(threshold, exclude)}
  end

  @spec precommit_checks(non_neg_integer(), [atom() | String.t()]) :: [Check.t()]
  defp precommit_checks(threshold, exclude) do
    [
      %Check{name: "format", command: "mix", args: ["format", "--check-formatted"]},
      %Check{name: "compile", command: "mix", args: ["compile", "--warnings-as-errors"]},
      %Check{name: "test", command: "mix", args: test_args(threshold, exclude)},
      %Check{name: "dialyzer", command: "mix", args: ["dialyzer.json"]},
      @credo_check,
      %Check{name: "doctor", command: "mix", args: ["doctor", "--raise"]},
      @sobelow_check
    ]
  end

  @spec test_args(non_neg_integer(), [atom() | String.t()]) :: [String.t()]
  defp test_args(threshold, exclude) do
    ["test.json", "--cover", "--cover-threshold", Integer.to_string(threshold)] ++
      Enum.flat_map(exclude, &["--exclude", to_string(&1)])
  end
end
