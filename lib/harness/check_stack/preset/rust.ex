defmodule Harness.CheckStack.Preset.Rust do
  @moduledoc """
  The standard Rust cargo-based verification check stack.

  Four checks, in the order they run: `fmt`, `clippy`, `test`, `build`.
  `cargo test` uses `--message-format=json` so the raw captured output is ready
  for future structured parsers without changing the preset contract.

  No `setup` bootstrap is declared — unlike Elixir's `mix deps.get`, `cargo`
  fetches crate dependencies on the first build/test invocation, so a fresh
  worktree needs no separate seed step.

  Use `preset/1` (or `Preset.fetch(:rust, opts)`) to parameterize for a specific
  project's needs (e.g. shared `--target-dir` for heavy deps, `release: false`
  to avoid double-compile, `env` for DATABASE_URL-driven test suites like rexex).
  Bare `preset/0` is unchanged.
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
  Returns the Rust preset as a `%Harness.CheckStack{}` (bare, unparameterized form).
  """
  @spec preset() :: CheckStack.t()
  def preset, do: preset([])

  @doc """
  Returns a parameterized Rust check stack as `%Harness.CheckStack{name: :rust}`.

  ## Options

    * `:target_dir` — value for cargo's `--target-dir`. Threads into clippy/test/build
      args (placed as `cargo <cmd> --target-dir DIR ...`); omitted for `fmt` (no
      compile step). Enables durable shared target dir for projects with expensive
      git-deps (e.g. reth in rexex) across isolated worktrees.
    * `:release` — if true (default), `build` keeps `--release`; if false, uses
      plain `cargo build` (debug profile). Avoids redundant full release compile
      when `cargo test` already produced a debug build the project can use.
    * `:timeout_per_check` — stack-level default timeout (ms or `:infinity`) for
      its checks; used by `Verification.run/2` when no explicit `:timeout` passed.
    * `:env` — `%{String.t() => Check.env_value()}` map stamped onto *every* check's
      `env` field (reusing the per-check `env` mechanism from Task 145). Supports
      `DATABASE_URL` (plain string), `{:harness, :test_database}` tokens, or `false`
      scrubs. For rexex: `env: %{"DATABASE_URL" => "postgres://.../rexex_test"}`.

  The returned stack can be passed directly to `Verification.run/2` or registered
  via a project's `preset: {:rust, opts}` (resolved at runtime by ProjectRegistry).
  """
  @spec preset(keyword()) :: CheckStack.t()
  def preset(opts) when is_list(opts) do
    target_dir = Keyword.get(opts, :target_dir)
    release? = Keyword.get(opts, :release, true)
    timeout_per_check = Keyword.get(opts, :timeout_per_check)
    env = Keyword.get(opts, :env, %{})

    %CheckStack{
      name: :rust,
      checks: apply_opts_to_checks(@checks, target_dir, release?, env),
      timeout_per_check: timeout_per_check
    }
  end

  @spec apply_opts_to_checks([Check.t()], String.t() | nil, boolean(), %{String.t() => Check.env_value()}) ::
          [Check.t()]
  defp apply_opts_to_checks(checks, target_dir, release?, env) do
    Enum.map(checks, fn
      %Check{name: "build", args: args} = ch ->
        build_args =
          args
          |> maybe_drop_release(release?)
          |> insert_target_dir(target_dir)

        %{ch | args: build_args, env: env}

      %Check{name: name} = ch when name in ["clippy", "test"] ->
        %{ch | args: insert_target_dir(ch.args, target_dir), env: env}

      ch ->
        %{ch | env: env}
    end)
  end

  @spec maybe_drop_release([String.t()], boolean()) :: [String.t()]
  defp maybe_drop_release(args, true), do: args
  defp maybe_drop_release(args, false), do: Enum.reject(args, &(&1 == "--release"))

  @spec insert_target_dir([String.t()], String.t() | nil) :: [String.t()]
  defp insert_target_dir(args, nil), do: args

  defp insert_target_dir([cmd | rest], dir) when cmd in ["clippy", "test", "build"] do
    [cmd, "--target-dir", dir | rest]
  end

  defp insert_target_dir(args, _dir), do: args
end
