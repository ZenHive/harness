defmodule Harness.Dashboard.OpsFeed.Op do
  @moduledoc """
  A single audit- or lander-lifecycle event for the dashboard ops feed.

  Sibling to `Harness.Run.Status` (which carries the implementer/reviewer/recovery
  STAGES of a run on `Harness.Dashboard.RunFeed`). Audit (`Harness.Audit`) and
  landing (`Harness.Lander`) run as **separate Oban workers** that never touch the
  run gen_statem, so their lifecycle is invisible to `RunFeed`. An `Op` is the
  small, fact-only event those modules broadcast on `Harness.Dashboard.OpsFeed`'s
  `harness:ops` topic instead.

  ## Facts, never a verdict (THE MANTRA)

  Every field is a *fact* the audit/lander code already produced — the stage it
  reached, which agent ran, the commit range, the resulting SHA, the raw outcome
  reason, the audit transcript. The builders below **relabel** a raw outcome tuple
  (e.g. `{:landed, sha}` → `stage: :landed`) into display facts; they never
  compute a verdict. The audit's clean/fixed judgment already lives in the agent's
  `.harness/audit.json` and `.audit/<sha>.md` — `detail`/`transcript` only relay it.

  `id` and `at` are stamped by `Harness.Dashboard.OpsFeed.broadcast/1`, so these
  builders stay pure (and doctestable).
  """

  @typedoc "Which separate-worker pipeline this event came from."
  @type kind :: :audit | :land

  @typedoc "A fact-only audit/land lifecycle event."
  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: kind(),
          stage: atom(),
          project: String.t() | nil,
          run_id: String.t() | nil,
          agent: String.t() | nil,
          target: String.t() | nil,
          range: String.t() | nil,
          sha: String.t() | nil,
          detail: String.t() | nil,
          transcript: String.t() | nil,
          at: DateTime.t() | nil
        }

  @enforce_keys [:kind, :stage]
  defstruct [:id, :kind, :stage, :project, :run_id, :agent, :target, :range, :sha, :detail, :transcript, :at]

  @doc """
  An audit run **started** — the third-family agent was selected and is about to run.

  ## Examples

      iex> op = Harness.Dashboard.OpsFeed.Op.audit_started("demo", "codex", "abc def")
      iex> {op.kind, op.stage, op.agent, op.range}
      {:audit, :started, "codex", "abc def"}
  """
  @spec audit_started(String.t() | nil, String.t() | nil, String.t() | nil) :: t()
  def audit_started(project, agent, range) do
    %__MODULE__{kind: :audit, stage: :started, project: project, agent: agent, range: range}
  end

  @doc """
  An audit run **settled** — relabels the `Harness.Audit.outcome/0` tuple into facts.

  `transcript` is the auditor's raw agent output (or `nil` when no agent ran), so
  the dashboard can show it: the audit is a real third-family agent run.

  ## Examples

      iex> op = Harness.Dashboard.OpsFeed.Op.audit_settled("demo", "codex", "r", {:audited, "deadbeef"}, "out")
      iex> {op.stage, op.sha, op.transcript}
      {:fixed, "deadbeef", "out"}

      iex> op = Harness.Dashboard.OpsFeed.Op.audit_settled("demo", "codex", "r", :no_changes, "out")
      iex> op.stage
      :clean
  """
  @spec audit_settled(String.t() | nil, String.t() | nil, String.t() | nil, term(), String.t() | nil) :: t()
  def audit_settled(project, agent, range, outcome, transcript) do
    {stage, sha, detail} = audit_outcome(outcome)

    %__MODULE__{
      kind: :audit,
      stage: stage,
      project: project,
      agent: agent,
      range: range,
      sha: sha,
      detail: detail,
      transcript: transcript
    }
  end

  @doc "A land attempt **started** for `request` (`Harness.Lander.request/0`)."
  @spec land_started(map()) :: t()
  def land_started(request), do: from_request(request, :landing, nil, nil)

  @doc """
  A non-terminal land **substage** (e.g. `:resolving` when the merge-resolver agent
  takes the conflicted worktree).
  """
  @spec land_stage(map(), atom()) :: t()
  def land_stage(request, stage), do: from_request(request, stage, nil, nil)

  @doc """
  A land attempt **settled** — relabels the `Harness.Lander.outcome/0` tuple into facts.

  ## Examples

      iex> req = %{project: %{name: "demo", target_branch: "main"}, run_id: "r1"}
      iex> op = Harness.Dashboard.OpsFeed.Op.land_settled(req, {:landed, "cafe"})
      iex> {op.stage, op.sha, op.run_id, op.target}
      {:landed, "cafe", "r1", "main"}
  """
  @spec land_settled(map(), term()) :: t()
  def land_settled(request, outcome) do
    {stage, sha, detail} = land_outcome(outcome)
    from_request(request, stage, sha, detail)
  end

  @doc """
  A task **blocked** by the merge-train cap, built from the Oban worker `args`
  (string-keyed) rather than the in-process `request`.
  """
  @spec blocked(map(), String.t()) :: t()
  def blocked(args, reason) do
    %__MODULE__{
      kind: :land,
      stage: :blocked,
      project: args["project_name"],
      run_id: args["run_id"],
      detail: reason
    }
  end

  @spec from_request(map(), atom(), String.t() | nil, String.t() | nil) :: t()
  defp from_request(request, stage, sha, detail) do
    %__MODULE__{
      kind: :land,
      stage: stage,
      project: project_name(request),
      run_id: Map.get(request, :run_id),
      target: target_branch(request),
      sha: sha,
      detail: detail
    }
  end

  @spec project_name(map()) :: String.t() | nil
  defp project_name(%{project: %{name: name}}), do: name
  defp project_name(_request), do: nil

  @spec target_branch(map()) :: String.t() | nil
  defp target_branch(%{project: %{target_branch: tb}}), do: tb
  defp target_branch(_request), do: nil

  # Mechanical relabel of an audit outcome tuple — no verdict computed; the
  # outcome already IS the audit code's settled result.
  @spec audit_outcome(term()) :: {atom(), String.t() | nil, String.t() | nil}
  defp audit_outcome({:audited, sha}), do: {:fixed, sha, "fixed + pushed"}
  defp audit_outcome(:no_changes), do: {:clean, nil, "clean (no changes)"}
  defp audit_outcome(:noop), do: {:noop, nil, "already audited"}
  defp audit_outcome({:push_rejected, _output}), do: {:push_rejected, nil, "target advanced; audit dropped"}
  defp audit_outcome({:skipped, reason}), do: {:skipped, nil, inspect(reason)}
  defp audit_outcome({:error, reason}), do: {:error, nil, inspect(reason)}
  defp audit_outcome(other), do: {:unknown, nil, inspect(other)}

  # Mechanical relabel of a land outcome tuple.
  @spec land_outcome(term()) :: {atom(), String.t() | nil, String.t() | nil}
  defp land_outcome({:landed, sha}), do: {:landed, sha, nil}
  defp land_outcome({:conflict, _output}), do: {:conflict, nil, "rebase conflict"}
  defp land_outcome({:push_rejected, _output}), do: {:push_rejected, nil, "target advanced under us"}
  defp land_outcome({:reflex_halt, reason}), do: {:reflex_halt, nil, inspect(reason)}
  defp land_outcome({:skipped, reason}), do: {:skipped, nil, inspect(reason)}
  defp land_outcome({:error, reason}), do: {:error, nil, inspect(reason)}
  defp land_outcome(other), do: {:unknown, nil, inspect(other)}
end
