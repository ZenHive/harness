defmodule Harness.CheckStack.Preset.Elixir do
  @moduledoc """
  The standard Elixir mix-based verification check stack.

  Five checks, in the order they run: `test`, `dialyzer`, `credo`, `doctor`,
  `sobelow`. `test` runs first so later checks reuse the `_build` it produces.
  Each command carries the flags that make its exit status a reliable
  pass/fail signal — `--exit` for sobelow, `--strict` for credo, the
  `mix test.json`/`mix dialyzer.json` AI-friendly variants for the rest.

  The credo check declares a `post_process` hook
  (`Harness.Verification.BaselineFilter.Credo`) so TagTODO findings on TODOs
  inherited from the dispatch base don't red the verdict — dispatched agents
  are graded only on TODOs they introduced.

  This module owns the canonical Elixir check list;
  `Harness.Verification.elixir_preset/0` delegates here for back-compat.
  """

  alias Harness.CheckStack
  alias Harness.Verification.Check

  @checks [
    %Check{name: "test", command: "mix", args: ["test.json"]},
    %Check{name: "dialyzer", command: "mix", args: ["dialyzer.json"]},
    %Check{
      name: "credo",
      command: "mix",
      args: ["credo", "--strict"],
      post_process: {Harness.Verification.BaselineFilter.Credo, :apply}
    },
    %Check{name: "doctor", command: "mix", args: ["doctor"]},
    %Check{name: "sobelow", command: "mix", args: ["sobelow", "--exit", "--skip"]}
  ]

  @doc """
  Returns the Elixir preset as a `%Harness.CheckStack{}`.

  `timeout_per_check` is left `nil` — the verification runner's default of
  10 minutes already accommodates a cold-PLT dialyzer run on this codebase.
  """
  @spec preset() :: CheckStack.t()
  def preset, do: %CheckStack{name: :elixir, checks: @checks}
end
