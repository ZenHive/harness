defmodule Harness.Projects.DispatchQA.Catalog do
  @moduledoc """
  Fleet contract for focused dispatch checks vs post-merge audit QA.

  Proposes command mappings for the 16 registered projects as of 2026-09-20 (harness_runtime).
  Consumer alias/instruction edits stay orchestrator-owned; this catalog records
  proposed command mappings and consumer write-sets.
  """

  @elixir_write_set ["mix.exs", "CLAUDE.md", "AGENTS.md"]

  @onchain_write_set [
    "mix.exs",
    "CLAUDE.md",
    "AGENTS.md",
    "packages/hieroglyph/mix.exs",
    "packages/hieroglyph/CLAUDE.md",
    "packages/hieroglyph/AGENTS.md",
    "packages/cartouche/mix.exs",
    "packages/cartouche/CLAUDE.md",
    "packages/cartouche/AGENTS.md",
    "packages/onchain/mix.exs",
    "packages/onchain/CLAUDE.md",
    "packages/onchain/AGENTS.md",
    "packages/onchain_aave/mix.exs",
    "packages/onchain_aave/CLAUDE.md",
    "packages/onchain_aave/AGENTS.md",
    "packages/onchain_aerodrome/mix.exs",
    "packages/onchain_aerodrome/CLAUDE.md",
    "packages/onchain_aerodrome/AGENTS.md",
    "packages/onchain_evm/mix.exs",
    "packages/onchain_evm/CLAUDE.md",
    "packages/onchain_evm/AGENTS.md",
    "packages/onchain_js/mix.exs",
    "packages/onchain_js/CLAUDE.md",
    "packages/onchain_js/AGENTS.md",
    "packages/onchain_tempo/mix.exs",
    "packages/onchain_tempo/CLAUDE.md",
    "packages/onchain_tempo/AGENTS.md"
  ]

  @aave_before "mix check.fast plus focused mix test.json on touched behavior; mix precommit for the full pre-land gate (test.json coverage >=85%, doctor, sobelow --skip); then mix dialyzer.json --quiet — dialyzer is NOT part of precommit and an uncaught pattern_match warning has turned main red before, so run it before approving. Run test.json and dialyzer.json bare; never prefix MIX_ENV."

  @aave_dispatch "mix format --check-formatted && mix compile --warnings-as-errors; focused mix test.json and risk-relevant security/live checks."

  @onchain_dispatch "Per-package gate: for each package the task touches, run cd packages/<name> && mix check.dispatch. Running mix check.dispatch at the repo root only prints this instruction and exits nonzero; the 8 packages live under packages/ (hieroglyph, cartouche, onchain, onchain_aave, onchain_aerodrome, onchain_evm, onchain_js, onchain_tempo)."

  @type entry :: %{
          name: String.t(),
          languages: nonempty_list(atom()),
          kind: atom(),
          before_check_command: String.t(),
          dispatch: String.t(),
          qa: String.t(),
          write_set: [String.t()],
          notes: String.t()
        }

  @doc "All 16 fleet entries, ordered by name."
  @spec all() :: [entry()]
  def all do
    Enum.sort_by(
      [
        aave_sim(),
        elixir("blockwatch", "mix precommit.full && mix test.json --cover"),
        elixir("bourse", "mix ci"),
        elixir("bourse_trading", "mix check.dispatch"),
        ccxt_distill(),
        elixir("delta_calc", "mix ci && mix doctor --raise && mix sobelow --skip --exit Low && mix test.json --cover"),
        elixir("harness", "mix precommit.full"),
        elixir("harness_agent_adapter", "mix precommit.full"),
        elixir("mpp", "mix precommit.full"),
        onchain_stack(),
        rmap(),
        elixir("starconiq", "mix precommit.full"),
        elixir("tapakly", "mix precommit.full"),
        elixir("trading_dashboard", "mix ci && mix doctor --raise && mix test.json --cover"),
        elixir("zen_quant", "mix ci"),
        elixir("zen_websocket", "mix precommit.full")
      ],
      & &1.name
    )
  end

  @doc "Looks up a catalog entry by project name."
  @spec entry(String.t()) :: entry() | nil
  def entry(name) when is_binary(name), do: Enum.find(all(), &(&1.name == name))

  @doc "True when switching check_command requires an evidenced QA pass."
  @spec requires_qa_pass?(entry()) :: boolean()
  def requires_qa_pass?(_entry), do: false

  @spec elixir(String.t(), String.t()) :: entry()
  defp elixir(name, qa) do
    %{
      name: name,
      languages: [:elixir],
      kind: :elixir,
      before_check_command: "mix check.dispatch",
      dispatch:
        "mix format --check-formatted && mix compile --warnings-as-errors; focused mix test.json and risk-relevant security/live checks.",
      qa: qa,
      write_set: @elixir_write_set,
      notes:
        "Explicit focused commands avoid inheriting full gates from an unchanged alias name. Existing aliases remain available for audit QA."
    }
  end

  @spec aave_sim() :: entry()
  defp aave_sim do
    %{
      name: "aave_sim",
      languages: [:elixir],
      kind: :aave_sim,
      before_check_command: @aave_before,
      dispatch: @aave_dispatch,
      qa: "mix precommit.full",
      write_set: @elixir_write_set,
      notes:
        "No full Dialyzer before approval. Dialyzer belongs in precommit.full QA. Repo has check.fast, not check.dispatch."
    }
  end

  @spec ccxt_distill() :: entry()
  defp ccxt_distill do
    %{
      name: "ccxt-distill",
      languages: [:typescript],
      kind: :typescript,
      before_check_command: "npm run check",
      dispatch: "npm run typecheck && npm run lint; focused tests for touched behavior",
      qa: "npm run check",
      write_set: ["package.json", "CLAUDE.md", "AGENTS.md"],
      notes: "Native npm scripts. npm run check (typecheck + lint + test) is complete QA."
    }
  end

  @spec onchain_stack() :: entry()
  defp onchain_stack do
    %{
      name: "onchain_stack",
      languages: [:elixir],
      kind: :onchain_stack,
      before_check_command: @onchain_dispatch,
      dispatch:
        "For each touched package under packages/<name>: mix format --check-formatted && mix compile --warnings-as-errors; focused mix test.json and risk-relevant security/live checks.",
      qa: "mix ci",
      write_set: @onchain_write_set,
      notes: "Dispatch stays per touched package. Root mix ci covers every package for QA."
    }
  end

  @spec rmap() :: entry()
  defp rmap do
    %{
      name: "rmap",
      languages: [:rust],
      kind: :rust,
      before_check_command: "cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test",
      dispatch: "cargo fmt --check && cargo clippy --all-targets -- -D warnings; focused cargo test for touched crates",
      qa: "cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test",
      write_set: ["Cargo.toml", "CLAUDE.md", "AGENTS.md"],
      notes: "Native cargo commands. Full cargo test stays in QA."
    }
  end
end
