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
  """

  alias Harness.Verification.Check

  @typedoc """
  A named verification check stack. See the module doc for field semantics.
  """
  @type t :: %__MODULE__{
          name: atom(),
          checks: [Check.t()],
          parser: module() | nil,
          timeout_per_check: timeout() | nil
        }

  @enforce_keys [:name, :checks]
  defstruct [:name, :checks, parser: nil, timeout_per_check: nil]
end
