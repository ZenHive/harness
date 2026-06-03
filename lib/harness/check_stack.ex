defmodule Harness.CheckStack do
  @moduledoc """
  A first-class verification check stack: a named bundle of
  `Harness.Verification.Check` commands, an optional default per-check timeout,
  and an optional structured-output parser.

  A `%CheckStack{}` is the typed equivalent of "a project's verification stack
  as data". The Elixir preset (`Harness.CheckStack.Preset.Elixir.preset/0`)
  carries the standard five-tool `mix` quality stack; future presets — Rust
  (Task 45), per-project stacks (Task 46) — return their own stacks the same
  way. `Harness.Verification.run/2` accepts a `%CheckStack{}` via its
  `:check_stack` option and uses the stack's `checks` and (when set)
  `timeout_per_check`.

  ## Fields

    * `name` — a short atom identifying the stack, used for logging and
      surface routing (e.g. `:elixir`, `:rust`). The same key
      `Harness.CheckStack.Preset.fetch/1` uses.
    * `checks` — the list of `Harness.Verification.Check`s the stack runs, in
      the order they should run. Order matters: the Elixir preset runs `test`
      first so later checks reuse the `_build` it produces.
    * `parser` — an optional callback module reserved for future per-language
      output-parsing logic (see Task 45's notes on `cargo --message-format=json`).
      No call site invokes it in the current codebase; it is a forward-looking
      slot kept on the struct so a preset can declare its parser without a
      later struct migration. `nil` means "no parser declared".
    * `timeout_per_check` — an optional default per-check timeout in
      milliseconds (or `:infinity`). When set, it becomes the default for
      `Harness.Verification.run/2` unless the caller passes an explicit
      `:timeout`. `nil` means "use the verification runner's default
      (10 minutes)".
    * `workdir` — the subdirectory, relative to the worktree root, this stack's
      checks execute in. Defaults to `""` (the repo root — the only behavior
      before multi-language projects). A multi-language monorepo registers one
      stack per language, each pointing at its own subdirectory (e.g. a Rust
      crate in `"rust"`, a Phoenix app in `"elixir"`). A git worktree is always
      repo-root-granular, so `workdir` is how a stack's checks reach the right
      buildable root within that worktree.
    * `setup` — non-grading bootstrap commands run before `checks`, in order,
      in the same `workdir`. A setup failure is an environment error
      (`{:setup_failed, _}` from `Harness.Verification.run/2`), not a red
      verdict — missing deps or a network blip during `mix deps.get` is never
      blamed on the agent. Defaults to `[]`. **Setup
      runs in both lifecycle phases** — at worktree-provision time
      (`Harness.Verification.prepare/2`, before the agent spawns) and again
      ahead of the grading checks (`run/2`) — so it must never carry anything
      the agent should not see: a file `setup` materializes lands in the
      agent's worktree.
    * `inject` — verification-only commands run after `setup` and before
      `checks`, in the same `workdir`, by `Harness.Verification.run/2` **but
      never by `prepare/2`**. This is the post-agent / pre-check injection step:
      because it skips the provisioning pass, it can materialize a file the
      agent must not see — a *hidden grader* (Mode B of the agent-evaluation
      corpus). A Mode-B benchmark withholds its grading test from the corpus
      repo and lists an `inject` command that copies the grader in from a
      host-side answer key right before checks run, so the agent is graded on a
      behavioral spec it never had access to. Like `setup`, an `inject` failure
      is an environment error (`{:inject_failed, _}`), not a red verdict.
      Defaults to `[]`.
  """

  alias Harness.Verification.Check

  @typedoc """
  A named verification check stack. See the module doc for field semantics.
  """
  @type t :: %__MODULE__{
          name: atom(),
          checks: [Check.t()],
          setup: [Check.t()],
          inject: [Check.t()],
          parser: module() | nil,
          timeout_per_check: timeout() | nil,
          workdir: String.t()
        }

  @enforce_keys [:name, :checks]
  defstruct [:name, :checks, setup: [], inject: [], parser: nil, timeout_per_check: nil, workdir: ""]
end
