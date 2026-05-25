defmodule Harness.AuditReview do
  @moduledoc """
  HIGH-tier second-grader dispatch for the `staged-review:audit-review` skill.

  Per the skill's stake-gated grading ladder, HIGH-tier fixes get a second-grader
  read by a *different* agent: Codex grades Claude, Claude grades Codex. This
  module wraps the dispatch as one synchronous call.

  ## Why this bypasses `Harness.Run` and the verification stack

  A grading run produces a *text verdict*, not a green/red verification verdict —
  the grader's words ARE the verdict. Routing through `Harness.Run` would force a
  fake verification check (shelling `true` so the always-runs `:no_checks` gate
  passes) and pollute the result store with non-task runs. Going straight to
  `Harness.AgentAdapter.Driver` keeps the dispatch semantics honest: spawn the
  agent, capture raw output, parse the sentinel, return.

  Repair loop, session resume, rmap integration, and the result store are all
  out of scope here. A grading run is one-shot and read-only.

  ## Verdict contract

  The grader's raw transcript is searched for a sentinel — the LAST occurrence
  of `<<<VERDICT:APPROVE>>>` or `<<<VERDICT:REJECT>>>` wins (last-match-wins
  handles graders that reason through both options before committing). The
  caller's prompt is responsible for instructing the grader to emit the sentinel
  on a line by itself at the end of its response; without one, the verdict is
  `:unclear`.

  The sentinel is plain ASCII (no JSON escaping), so substring matching on the
  raw transcript works for every adapter — Claude's `stream-json`, Codex's
  `--json`, Grok's `streaming-json`, and Antigravity's plain text alike.

  See the codified skill at
  `~/_DATA/code/claude-marketplace-elixir/plugins/staged-review/skills/audit-review/SKILL.md`
  § "Stake-gated fix verification".
  """

  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome

  @sentinel_approve "<<<VERDICT:APPROVE>>>"
  @sentinel_reject "<<<VERDICT:REJECT>>>"

  @agents %{
    claude: Harness.AgentAdapter.Claude,
    codex: Harness.AgentAdapter.Codex,
    cursor: Harness.AgentAdapter.Cursor,
    grok: Harness.AgentAdapter.Grok,
    antigravity: Harness.AgentAdapter.Antigravity,
    pi: Harness.AgentAdapter.Pi
  }

  # Auto-pairs only the two agents that audit-review's HIGH tier explicitly
  # names: Codex grades Claude, Claude grades Codex. Other implementers must
  # pass :grader explicitly — there is no defensible default for grok/cursor/etc.
  # TODO: extend auto-pairing once a cost-tier capability surface on
  # Harness.AgentRegistry lets us pick the cheaper-but-capable grader automatically.
  @grader_pairs %{claude: :codex, codex: :claude}

  @typedoc "What the grader concluded about the fix."
  @type verdict :: :approve | :reject | :unclear

  @typedoc "A completed grading dispatch."
  @type result :: %{
          verdict: verdict(),
          outcome: Outcome.t(),
          grader: module()
        }

  @doc """
  Dispatches a focused review of a fix to the grader and returns the verdict.

  ## Required options

    * `:implementer` — atom (`:claude`, `:codex`, `:cursor`, `:grok`,
      `:antigravity`, `:pi`) identifying which agent built the fix. Used to
      auto-derive `:grader` when not explicitly set.
    * `:sha` — the commit SHA being audited. Composed into the synthetic
      `Invocation` `task_id` (`"audit-<sha>-grader"`); never read from disk.
    * `:prompt` — the focused-review prompt body. The caller (audit-review
      skill, or a test) builds this; this module does NOT generate prompt
      content. The prompt MUST instruct the grader to emit one of
      `<<<VERDICT:APPROVE>>>` or `<<<VERDICT:REJECT>>>` on a line by itself.

  ## Optional options

    * `:grader` — either a known-agent atom or a module implementing
      `Harness.AgentAdapter`. Defaults to the opposite of `:implementer`
      (`:claude → :codex`, `:codex → :claude`); other implementers require an
      explicit `:grader`. A module value supports test stubs without expanding
      the known-agents table.
    * `:cwd` — working directory the grader spawns in. Defaults to
      `File.cwd!/0`. The grader runs in `:autonomous` permission mode; the
      prompt is responsible for instructing it to be read-only.
    * `:model` — optional model id forwarded to the grader via
      `Harness.AgentAdapter.Invocation.model`. Defaults to `nil`, leaving the
      grader on its adapter-default model. Use to pin a specific model for
      grading (e.g. `"claude-opus-4-7"` when grading higher-stakes fixes).
    * `:adapter_opts` — pass-through escape hatch for per-adapter knobs.
    * `:total_timeout` / `:idle_timeout` — forwarded to
      `Harness.AgentAdapter.Driver`; both default to its application config.

  ## Return values

    * `{:ok, %{verdict:, outcome:, grader:}}` for any dispatch that *spawned*,
      including timeouts and mid-run port errors (the verdict is `:unclear`
      when no sentinel is present, and the caller can inspect `outcome.kind`
      and `outcome.output` for context).
    * `{:error, reason}` only when dispatch could not start: invalid options,
      unknown agent, or the adapter's `build_command/1` / `System.find_executable/1`
      failing.
  """
  @spec grade_fix(keyword()) :: {:ok, result()} | {:error, term()}
  def grade_fix(opts) when is_list(opts) do
    with {:ok, implementer} <- fetch_implementer(opts),
         {:ok, sha} <- fetch_sha(opts),
         {:ok, prompt} <- fetch_prompt(opts),
         {:ok, grader_module} <- resolve_grader(implementer, opts),
         invocation = build_invocation(sha, prompt, opts),
         driver_opts = Keyword.take(opts, [:total_timeout, :idle_timeout]),
         {:ok, %Outcome{} = outcome} <- Driver.run(grader_module, invocation, driver_opts) do
      {:ok,
       %{
         verdict: extract_verdict(outcome.output),
         outcome: outcome,
         grader: grader_module
       }}
    end
  end

  @doc """
  Extracts a verdict from a raw grader transcript.

  Public so the audit-review skill (or tests) can re-parse a previously
  captured transcript without re-dispatching. Returns `:approve`, `:reject`,
  or `:unclear` per the sentinel rules in the moduledoc — last-match-wins
  when both sentinels appear, so a grader that reasons through both options
  before committing at the end still settles to its final answer.
  """
  @spec extract_verdict(binary()) :: verdict()
  def extract_verdict(output) when is_binary(output) do
    approve_pos = last_match_position(output, @sentinel_approve)
    reject_pos = last_match_position(output, @sentinel_reject)

    case {approve_pos, reject_pos} do
      {nil, nil} -> :unclear
      {_, nil} -> :approve
      {nil, _} -> :reject
      {a, r} when a > r -> :approve
      {_, _} -> :reject
    end
  end

  @doc """
  Returns the default grader adapter module for an implementer.

  Public so callers (the audit-review skill, tests) can introspect the
  auto-pair mapping without dispatching. Pairs `:claude ↔ :codex`; other
  implementers return `{:error, {:no_default_grader, implementer}}`.

  ## Examples

      iex> Harness.AuditReview.default_grader(:claude)
      {:ok, Harness.AgentAdapter.Codex}

      iex> Harness.AuditReview.default_grader(:codex)
      {:ok, Harness.AgentAdapter.Claude}

      iex> Harness.AuditReview.default_grader(:grok)
      {:error, {:no_default_grader, :grok}}
  """
  @spec default_grader(atom()) :: {:ok, module()} | {:error, {:no_default_grader, atom()}}
  def default_grader(implementer) when is_atom(implementer) do
    case Map.fetch(@grader_pairs, implementer) do
      {:ok, grader_atom} -> {:ok, Map.fetch!(@agents, grader_atom)}
      :error -> {:error, {:no_default_grader, implementer}}
    end
  end

  @spec fetch_implementer(keyword()) :: {:ok, atom()} | {:error, term()}
  defp fetch_implementer(opts) do
    case Keyword.fetch(opts, :implementer) do
      {:ok, atom} when is_atom(atom) and not is_nil(atom) -> {:ok, atom}
      :error -> {:error, {:missing_option, :implementer}}
      {:ok, other} -> {:error, {:invalid_option, :implementer, other}}
    end
  end

  @spec fetch_sha(keyword()) :: {:ok, String.t()} | {:error, term()}
  defp fetch_sha(opts) do
    case Keyword.fetch(opts, :sha) do
      {:ok, sha} when is_binary(sha) and byte_size(sha) > 0 -> {:ok, sha}
      :error -> {:error, {:missing_option, :sha}}
      {:ok, other} -> {:error, {:invalid_option, :sha, other}}
    end
  end

  @spec fetch_prompt(keyword()) :: {:ok, String.t()} | {:error, term()}
  defp fetch_prompt(opts) do
    case Keyword.fetch(opts, :prompt) do
      {:ok, prompt} when is_binary(prompt) and byte_size(prompt) > 0 -> {:ok, prompt}
      :error -> {:error, {:missing_option, :prompt}}
      {:ok, other} -> {:error, {:invalid_option, :prompt, other}}
    end
  end

  @spec resolve_grader(atom(), keyword()) :: {:ok, module()} | {:error, term()}
  defp resolve_grader(implementer, opts) do
    case Keyword.get(opts, :grader) do
      nil -> default_grader(implementer)
      atom when is_atom(atom) -> resolve_grader_atom(atom)
      other -> {:error, {:invalid_option, :grader, other}}
    end
  end

  @spec resolve_grader_atom(atom()) :: {:ok, module()} | {:error, term()}
  defp resolve_grader_atom(atom) do
    cond do
      Map.has_key?(@agents, atom) ->
        {:ok, Map.fetch!(@agents, atom)}

      Code.ensure_loaded?(atom) and function_exported?(atom, :build_command, 1) ->
        {:ok, atom}

      true ->
        {:error, {:unknown_agent, atom}}
    end
  end

  @spec build_invocation(String.t(), String.t(), keyword()) :: Invocation.t()
  defp build_invocation(sha, prompt, opts) do
    %Invocation{
      prompt: prompt,
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      task_id: "audit-#{sha}-grader",
      model: Keyword.get(opts, :model),
      adapter_opts: Keyword.get(opts, :adapter_opts, [])
    }
  end

  @spec last_match_position(binary(), binary()) :: non_neg_integer() | nil
  defp last_match_position(output, pattern) do
    case :binary.matches(output, pattern) do
      [] -> nil
      matches -> matches |> List.last() |> elem(0)
    end
  end
end
