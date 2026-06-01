defmodule Harness.CheckStack.Preset.Rust do
  @moduledoc """
  The standard Rust cargo-based verification check stack.

  Four checks, in the order they run: `fmt`, `clippy`, `test`, `build`.
  `cargo test` uses `--message-format=json` so the raw captured output is ready
  for future structured parsers without changing the preset contract.

  No `setup` bootstrap is declared — unlike Elixir's `mix deps.get`, `cargo`
  fetches crate dependencies on the first build/test invocation, so a fresh
  worktree needs no separate seed step.
  """

  alias Harness.CheckStack
  alias Harness.Verification.Check

  @checks [
    %Check{name: "fmt", role: :format, command: "cargo", args: ["fmt", "--check"]},
    %Check{name: "clippy", role: :lint, command: "cargo", args: ["clippy", "--", "-D", "warnings"]},
    %Check{name: "test", role: :test, command: "cargo", args: ["test", "--message-format=json"]},
    %Check{name: "build", role: :build, command: "cargo", args: ["build", "--release"]}
  ]

  @doc """
  Returns the Rust preset as a `%Harness.CheckStack{}`.
  """
  @spec preset() :: CheckStack.t()
  def preset, do: %CheckStack{name: :rust, checks: @checks}
end
