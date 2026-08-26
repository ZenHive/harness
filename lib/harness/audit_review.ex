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
  `Harness.AgentDriver` keeps the dispatch semantics honest: spawn the
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

  ## Configuring grader pairs

  `default_grader/1` reads the implementer → grader pairing from config, falling
  back to the built-in `%{claude: :codex, codex: :claude}` default when unset:

      config :harness, :audit_review, grader_pairs: %{claude: :codex, codex: :claude}

  Override it to re-pair (e.g. point Claude at Grok) or to add auto-pairs for
  implementers the default leaves unpaired. An implementer absent from the
  configured map still returns `{:error, {:no_default_grader, implementer}}`.
  """

  use Descripex, namespace: "/audit_review"

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentDriver
  alias Harness.AgentRegistry
  alias Harness.AgentRules

  @sentinel_approve "<<<VERDICT:APPROVE>>>"
  @sentinel_reject "<<<VERDICT:REJECT>>>"

  # Built-in default: auto-pairs only the two agents that audit-review's HIGH
  # tier explicitly names — Codex grades Claude, Claude grades Codex. Other
  # implementers must pass :grader explicitly (no defensible default for
  # grok/cursor/etc.) unless an operator adds them via the
  # `config :harness, :audit_review, grader_pairs: %{...}` override read in
  # default_grader/1. Cost-tier-aware grader selection can be layered onto
  # AgentRegistry later, but the in-code default stays deliberately explicit.
  @default_grader_pairs %{claude: :codex, codex: :claude}

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
         {:ok, %Outcome{} = outcome} <- AgentDriver.run(grader_module, invocation, driver_opts) do
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
    case Map.fetch(grader_pairs(), implementer) do
      {:ok, grader_atom} -> AgentRegistry.module_for_agent(grader_atom)
      :error -> {:error, {:no_default_grader, implementer}}
    end
  end

  # Config override wins; the built-in pair is the fallback when the key is unset.
  @spec grader_pairs() :: %{optional(atom()) => atom()}
  defp grader_pairs do
    :harness
    |> Application.get_env(:audit_review, [])
    |> Keyword.get(:grader_pairs, @default_grader_pairs)
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
    case AgentRegistry.module_for_agent(atom) do
      {:ok, _module} = ok ->
        ok

      {:error, _} ->
        if Code.ensure_loaded?(atom) and function_exported?(atom, :build_command, 1) do
          {:ok, atom}
        else
          {:error, {:unknown_agent, atom}}
        end
    end
  end

  @spec build_invocation(String.t(), String.t(), keyword()) :: Invocation.t()
  defp build_invocation(sha, prompt, opts) do
    %Invocation{
      prompt: prompt,
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      log_tag: "audit-#{sha}-grader",
      model: Keyword.get(opts, :model),
      rule_content: AgentRules.render(),
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
