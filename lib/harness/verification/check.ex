defmodule Harness.Verification.Check do
  @moduledoc """
  The specification of one verification check: a name, an executable, and its
  argument vector.

  A list of `Check`s is the verification runner's input — the target project's
  check stack expressed as data. `Harness.Verification.elixir_preset/0` returns
  the default list; callers supply their own via the `:checks` option to
  `Harness.Verification.run/2` or the `:harness, :verification` application
  config.
  """

  alias Harness.Verification.Result

  @typedoc """
  A post-process hook that re-grades a check's `Harness.Verification.Result`
  after the process exits.

  Invoked as `module.function(result, opts)`, where `opts` carries
  `:worktree_path` and (when set) `:base_ref` — the SHA the worktree branch
  was forked from. The hook returns a (possibly mutated) `Result`. It must
  never raise: a hook that can't grade defensively returns the input result
  unchanged so the original pass/fail signal is preserved.

  The built-in use case is the credo TagTODO baseline filter
  (`Harness.Verification.BaselineFilter.Credo`), which drops TagTODO findings
  on lines whose `# TODO` already existed at the dispatch base — so a
  dispatched agent is only graded on TODOs *they* introduced.
  """
  @type post_process :: {module(), atom()}

  @typedoc """
  One check.

    * `name` — a short human label, surfaced in the verdict and logs
      (e.g. `"test"`).
    * `role` — optional semantic category for consumers that need to reason
      across languages (`:format`, `:lint`, `:test`, `:build`, etc.).
    * `command` — the executable to run, resolved on `PATH` (e.g. `"mix"`).
    * `args` — the argument vector, always a list, never a shell string
      (e.g. `["test.json"]`).
    * `post_process` — optional `{module, function}` hook that re-grades the
      check's `Harness.Verification.Result` (see `t:post_process/0`); `nil`
      means grade purely on process exit status.
  """
  @type t :: %__MODULE__{
          name: String.t(),
          role: atom() | nil,
          command: String.t(),
          args: [String.t()],
          post_process: post_process() | nil
        }

  @enforce_keys [:name, :command, :args]
  defstruct [:name, :command, :args, role: nil, post_process: nil]

  @doc """
  Invokes a `post_process` hook on `result`, returning the (possibly re-graded)
  `Harness.Verification.Result`.

  No-op when the check declared no hook. `opts` is the keyword list the hook
  receives — `Harness.Verification` populates `:worktree_path` and, when known,
  `:base_ref`.
  """
  @spec apply_post_process(t(), Result.t(), keyword()) :: Result.t()
  def apply_post_process(%__MODULE__{post_process: nil}, %Result{} = result, _opts), do: result

  def apply_post_process(%__MODULE__{post_process: {module, function}}, %Result{} = result, opts) do
    apply(module, function, [result, opts])
  end
end
