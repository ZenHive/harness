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

  use Descripex, namespace: "/audit_review"

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

  api(:grade_fix, "Dispatch a HIGH-tier cross-agent grader for one fix and return the verdict.",
    params: [
      opts: [
        kind: :value,
        description:
          "Keyword list. Required: :implementer (atom — :claude/:codex/:cursor/:grok/:antigravity/:pi), :sha (commit SHA), :prompt (review prompt that MUST instruct the grader to emit <<<VERDICT:APPROVE>>> or <<<VERDICT:REJECT>>> on its own line). Optional: :grader (atom or module — defaults to opposite of :implementer for claude/codex; other implementers must pass explicitly), :cwd (defaults to File.cwd!/0 — pass explicitly when grading another repo), :model (pin a model id like claude-opus-4-7), :adapter_opts, :total_timeout, :idle_timeout."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{verdict:, outcome:, grader:}} for any spawned dispatch (verdict is :approve/:reject/:unclear). {:error, reason} only when dispatch could not start."
    },
    errors: [
      missing_option: "A required :implementer / :sha / :prompt option was not provided.",
      invalid_option: "An option value had the wrong shape (e.g. :grader was not an atom).",
      unknown_agent: "The :grader atom did not match a known agent and is not a loaded adapter module.",
      no_default_grader: "Implementer has no auto-paired grader and :grader was not supplied."
    ]
  )

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

  api(:extract_verdict, "Extract a verdict from a raw grader transcript without re-dispatching.",
    params: [
      output: [
        kind: :value,
        description:
          "Raw grader transcript string. Searched for <<<VERDICT:APPROVE>>> / <<<VERDICT:REJECT>>> sentinels (last-match-wins)."
      ]
    ],
    returns: %{
      type: :atom,
      description:
        ":approve when only/last sentinel was APPROVE, :reject when only/last was REJECT, :unclear when neither appears."
    }
  )

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

  api(:default_grader, "Return the auto-paired grader adapter module for an implementer agent.",
    params: [
      implementer: [
        kind: :value,
        description:
          "Implementer agent atom (:claude or :codex auto-pair; other agents return {:error, {:no_default_grader, implementer}})."
      ]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, module()} for :claude ↔ :codex, otherwise {:error, {:no_default_grader, implementer}}."
    }
  )

  @doc """
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
