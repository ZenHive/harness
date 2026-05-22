defmodule Harness.AgentAdapter.Codex do
  @moduledoc """
  The headless adapter for Codex — driven via `codex exec` over an OTP port.

  harness's second concrete `Harness.AgentAdapter`, and the first real exercise
  of the behaviour as a *contract*. Codex's invocation is structurally unlike
  Claude's — `exec` is a subcommand, raw output is `--json` rather than
  `--output-format stream-json`, and resuming swaps in a whole different
  subcommand (`exec resume`) instead of adding a flag — so building it against
  the unchanged behaviour is what proves the contract is not Claude-shaped.

  Like every adapter it is thin: the real logic is `build_command/1` assembling
  the headless command line. Raw output is captured and passed through
  unparsed; termination is detected from the port closing, never from the exit
  code.

  ## Invocation

  Runs `codex exec --json` so the full agent transcript streams out as raw
  JSONL events, captured verbatim. The working directory is wired by
  `Harness.AgentAdapter.invoke/2` (the port's `:cd`), not by Codex's own `--cd`
  flag.

  ## Permission mode

  `Harness.AgentAdapter.Invocation`'s `permission_mode` is checked against the
  one mode Codex's headless mode supports here: `:autonomous`, harness's
  unattended baseline. It maps to `--dangerously-bypass-approvals-and-sandbox`
  — Codex's flag for "skip every confirmation prompt and run without a sandbox",
  documented for exactly harness's situation: an externally sandboxed, throwaway
  worktree with no human to answer prompts. An unrecognized mode is a
  `build_command/1` error rather than a silent fallback.

  ## Session resume

  Resuming swaps the `exec` subcommand for `exec resume --last`, which reloads
  the most recent recorded session **in the working directory** (Codex filters
  recorded sessions by `cwd` unless `--all` is given). That is exact here
  because every harness job owns one worktree, so "the most recent session in
  `cwd`" is unambiguous — the same reasoning as the Claude adapter's
  `--continue`. Harness cannot obtain a Codex session id without parsing agent
  output, which the raw-passthrough design forbids, so `--last` is the only
  viable resume channel. The `Invocation` `session` field therefore carries the
  `:resume` sentinel, not a literal token; any other non-`nil` value is an
  error.
  """

  @behaviour Harness.AgentAdapter

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.OSProcess
  alias Harness.AgentAdapter.Run

  # The permission modes Codex's headless mode supports. :autonomous is the
  # universal baseline; it maps to running with every confirmation skipped.
  @permission_modes [:autonomous]

  @doc """
  Declares Codex's headless capabilities: session resume and streaming output,
  with `:autonomous` the only permission mode.
  """
  @impl Harness.AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities, do: %Capabilities{session_resume: true}

  @doc """
  Builds the `codex exec` headless command line for `invocation`.

  Returns `{:error, {:unsupported_permission_mode, mode}}` for a permission mode
  outside `capabilities/0`, and `{:error, {:unsupported_session_token, value}}`
  when `session` is neither `nil` nor `:resume` (see the module doc — Codex
  resumes the latest session in `cwd` via `resume --last`, not a token).
  """
  @impl Harness.AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, Harness.AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with :ok <- check_permission_mode(invocation.permission_mode),
         {:ok, subcommand, resume} <- session_args(invocation.session) do
      argv =
        subcommand ++
          ["--json", "--dangerously-bypass-approvals-and-sandbox"] ++
          model_args(invocation.model) ++
          resume ++
          [invocation.prompt]

      env = Map.to_list(invocation.env)
      {:ok, {"codex", argv, env}}
    end
  end

  @doc """
  Classifies one port message: a data chunk is raw output, an exit status is
  termination, anything else is ignored.
  """
  @impl Harness.AgentAdapter
  @spec classify_message(term(), Run.t()) :: Harness.AgentAdapter.classification()
  def classify_message({port, {:data, data}}, %Run{port: port} = run), do: {:output, data, run}

  def classify_message({port, {:exit_status, status}}, %Run{port: port} = run), do: {:terminated, run, status}

  def classify_message(_message, _run), do: :ignore

  @doc """
  Kills an in-flight run, delegating to the shared `Harness.AgentAdapter.OSProcess.kill/1`.
  """
  @impl Harness.AgentAdapter
  @spec terminate(Run.t()) :: :ok
  def terminate(%Run{} = run), do: OSProcess.kill(run)

  @spec check_permission_mode(atom()) ::
          :ok | {:error, {:unsupported_permission_mode, atom()}}
  defp check_permission_mode(mode) when mode in @permission_modes, do: :ok
  defp check_permission_mode(mode), do: {:error, {:unsupported_permission_mode, mode}}

  # The session value selects the `exec` subcommand and any resume flag:
  # `nil` is a fresh `exec`, `:resume` is `exec resume … --last`. The `--last`
  # flag must sit immediately before the prompt — with it set, Codex's first
  # positional binds to the prompt rather than to an (omitted) session id.
  @spec session_args(term()) ::
          {:ok, [String.t()], [String.t()]} | {:error, {:unsupported_session_token, term()}}
  defp session_args(nil), do: {:ok, ["exec"], []}
  defp session_args(:resume), do: {:ok, ["exec", "resume"], ["--last"]}
  defp session_args(other), do: {:error, {:unsupported_session_token, other}}

  @spec model_args(String.t() | nil) :: [String.t()]
  defp model_args(nil), do: []
  defp model_args(model) when is_binary(model), do: ["--model", model]
end
