defmodule Harness.Lander.Resolver do
  @moduledoc """
  Spawns a cross-family merge-resolver agent to reconcile a rebase conflict in
  the lander's open detached landing worktree (Task 189).

  ## Why an agent, not code

  A clean fast-forward land is pure git mechanics (no agent). A *rebase
  conflict* is a judgment call — keep both sides, reconcile overlapping intents
  — exactly the kind of meaning-interpretation the agent-gate rule reserves for
  an AI. The motivating case (landing task 177 over 182): two runs each added an
  adjacent test; the resolution was "keep both", which a blind re-dispatch
  cannot make and a resolver agent can.

  ## Contract

  `resolve/2` is the agent half only: it selects a cross-family resolver,
  builds the prompt (conflicted files + both sides' intents), and drives the
  agent to edit the worktree. It returns `:ok` once the agent *ran* (any
  outcome — the agent is an attempt, never a gate), or `{:error, reason}` when
  no resolver could be selected/spawned. The mechanical gate — staging,
  asserting zero leftover markers, `git rebase --continue` — stays in
  `Harness.Lander`, which aborts and falls back to the existing re-dispatch
  path on any failure. **A still-conflicted tree is never landed.**

  It does NOT re-run the project checks or re-grade the diff: the reviewer
  already approved both sides.

  ## Known failure mode (2026-06-15 ccxt-distill)

  Tasks 19 + 2 auto-landed with `:conflict_retained`: the resolver agent ran on
  same-function `SUBCOMMANDS` / CLI-registration conflicts but left markers behind.
  Durable evidence is the retained branch, not the agent transcript (resolver
  output is not persisted). The gap was prompt context — file lists and commit
  logs alone do not show the marker regions; same-list additive edits need
  explicit keep-both guidance. Task 293 adds authoritative conflict excerpts
  plus same-function/same-list instructions in `build_prompt/3`.

  ## Cross-family selection

  Same discipline as the reviewer gate — the resolver's family must differ from
  the implementer's, and it must be reviewer-eligible. The run's own reviewer
  (which already approved both sides, is cross-family by construction, and is
  eligible) is preferred; otherwise the first eligible cross-family agent in the
  registry is used.
  """

  alias Harness.Agent.Settings
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentRegistry
  alias Harness.Git
  alias Harness.Worktree

  @max_conflict_excerpt_chars 4_000

  @doc """
  Drives a cross-family agent to reconcile the conflict in `worktree`.

  `opts`: `:implementer` / `:reviewer` (agent atoms or strings — routing),
  `:task_id` (the run's task, for prompt context), `:base_sha` (origin/<target>
  tip, for the "ours" intent log). Returns `:ok` when the agent ran, or
  `{:error, reason}` when no resolver could be selected or spawned.
  """
  @spec resolve(Worktree.t(), keyword()) :: :ok | {:error, term()}
  def resolve(%Worktree{path: path} = worktree, opts) do
    with {:ok, module} <- select_resolver(normalize(opts[:implementer]), normalize(opts[:reviewer])),
         {:ok, [_ | _] = files} <- Git.conflicted_files(path),
         {:ok, _outcome} <- Driver.run(module, invocation(build_prompt(path, files, opts), worktree, opts)) do
      :ok
    else
      {:ok, []} -> {:error, :no_conflicted_files}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec select_resolver(atom() | nil, atom() | nil) :: {:ok, module()} | {:error, :no_resolver}
  def select_resolver(implementer, reviewer) do
    case reviewer_resolver(reviewer, implementer) do
      {:ok, module} -> {:ok, module}
      :error -> first_cross_family(implementer)
    end
  end

  # The run's reviewer already approved both sides and is cross-family — prefer
  # it. `:error` when there is no recorded reviewer, it equals the implementer,
  # or it is no longer dispatchable, so selection falls through to the registry.
  @spec reviewer_resolver(atom() | nil, atom() | nil) :: {:ok, module()} | :error
  defp reviewer_resolver(nil, _implementer), do: :error

  defp reviewer_resolver(reviewer, implementer) do
    with true <- reviewer != implementer,
         {:ok, module} <- AgentRegistry.module_for_agent(reviewer),
         true <- dispatchable?(reviewer, module) do
      {:ok, module}
    else
      _other -> :error
    end
  end

  @spec first_cross_family(atom() | nil) :: {:ok, module()} | {:error, :no_resolver}
  defp first_cross_family(implementer) do
    AgentRegistry.agents()
    |> Enum.reject(fn {agent, _module} -> agent == implementer end)
    |> Enum.find(fn {agent, module} -> dispatchable?(agent, module) end)
    |> case do
      {_agent, module} -> {:ok, module}
      nil -> {:error, :no_resolver}
    end
  end

  # Reuses the reviewer-eligibility gate (Agent.Settings) + availability/install
  # registry — the resolver must be a trusted, present, enabled agent.
  @spec dispatchable?(atom(), module()) :: boolean()
  defp dispatchable?(agent, module) do
    AgentRegistry.installed?(module) and AgentRegistry.available?(module) and
      Settings.enabled?(agent) and Settings.reviewer_eligible?(agent)
  end

  @doc false
  @spec build_prompt(String.t(), [String.t()], keyword()) :: String.t()
  def build_prompt(path, files, opts) do
    """
    You are the cross-family MERGE-CONFLICT RESOLVER for a harness auto-land.

    A reviewer-approved run is being rebased onto its target branch and hit a
    rebase conflict. BOTH sides were already reviewed and approved — your ONLY
    job is to reconcile the conflict markers so both intents survive. You are
    NOT re-reviewing, re-grading, or re-running any checks.

    Conflicted files (resolve every one; leave ZERO conflict markers):
    #{Enum.map_join(files, "\n", &("  - " <> &1))}

    The change being landed ("theirs", task ##{opts[:task_id]}):
    #{their_intent(path)}

    Already on the target branch ("ours", landed since this run branched):
    #{our_intent(path, opts[:base_sha])}

    Conflict excerpts (authoritative marker regions; resolve these in place):
    #{conflict_excerpts(path, files)}

    How to resolve:
    - Open each conflicted file and reconcile every <<<<<<< / ======= / >>>>>>> region.
    - Default to KEEPING BOTH sides when the changes are additive (two new
      tests, two new clauses, adjacent edits) — "keep both" is the common case.
    - For same function, same list, and same registration-block conflicts, assume they are often
      additive too: keep every added command, test, clause, or list entry unless
      the two sides are truly incompatible.
    - Preserve the intent of both sides; never drop either's work.
    - Remove every conflict marker. Do NOT stage or commit — just edit the files.
    - Do NOT run the project's tests or checks; do NOT re-review the diff.

    When every marker is reconciled, stop. Harness stages the result and
    continues the rebase.
    """
  end

  @spec conflict_excerpts(String.t(), [String.t()]) :: String.t()
  defp conflict_excerpts(path, files) do
    Enum.map_join(files, "\n", &conflict_excerpt(path, &1))
  end

  @spec conflict_excerpt(String.t(), String.t()) :: String.t()
  defp conflict_excerpt(path, file) do
    case File.read(Path.join(path, file)) do
      {:ok, content} ->
        format_conflict_excerpt(file, content)

      {:error, reason} ->
        "  - #{file}: unable to read conflicted file (#{inspect(reason)})"
    end
  end

  @spec format_conflict_excerpt(String.t(), String.t()) :: String.t()
  defp format_conflict_excerpt(file, content) do
    case Regex.scan(~r/<<<<<<<[\s\S]*?>>>>>>>[^\n]*(?:\n|$)/, content) do
      [] ->
        "  - #{file}: no conflict markers found in current file snapshot"

      matches ->
        """
          - #{file}:
        #{matches |> Enum.map_join("\n", &hd/1) |> excerpt_limit()}
        """
    end
  end

  @spec excerpt_limit(String.t()) :: String.t()
  defp excerpt_limit(content) do
    if String.length(content) > @max_conflict_excerpt_chars do
      String.slice(content, 0, @max_conflict_excerpt_chars) <> "\n...[truncated]"
    else
      content
    end
  end

  # "theirs" during a rebase is the run's commit currently being replayed
  # (REBASE_HEAD); "ours" is the target history already laid down. Both are
  # best-effort context — the markers in the files are the authoritative diff.
  @spec their_intent(String.t()) :: String.t()
  defp their_intent(path), do: git_log(path, "REBASE_HEAD", 5)

  @spec our_intent(String.t(), String.t() | nil) :: String.t()
  defp our_intent(_path, nil), do: "(unavailable)"
  defp our_intent(path, base_sha), do: git_log(path, base_sha, 8)

  @spec git_log(String.t(), String.t(), pos_integer()) :: String.t()
  defp git_log(path, ref, count) do
    case Git.run(["log", "--format=  %h %s", "-n", Integer.to_string(count), ref], path) do
      {:ok, ""} -> "(none)"
      {:ok, output} -> String.trim_trailing(output)
      {:error, _reason} -> "(unavailable)"
    end
  end

  @spec invocation(String.t(), Worktree.t(), keyword()) :: Invocation.t()
  defp invocation(prompt, %Worktree{path: path}, opts) do
    %Invocation{
      prompt: prompt,
      cwd: path,
      task_id: "#{opts[:task_id]}-resolve",
      permission_mode: :autonomous
    }
  end

  # Unknown strings (no matching agent atom) normalize to nil rather than
  # raising — an unrecognized implementer/reviewer just means "no preferred
  # reviewer", and selection falls through to the registry scan.
  @spec normalize(atom() | String.t() | nil) :: atom() | nil
  defp normalize(nil), do: nil
  defp normalize(agent) when is_atom(agent), do: agent

  defp normalize(agent) when is_binary(agent) do
    String.to_existing_atom(agent)
  rescue
    ArgumentError -> nil
  end
end
