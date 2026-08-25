defmodule Harness.Run.Review do
  @moduledoc """
  The reviewer AI's verdict artifact — `.harness/review.json` — read mechanically.

  The cross-family reviewer is THE gate of the agent-gate workflow: it reviews
  the implementer's work, runs the project's checks itself, fixes inline, and
  writes this file in the run worktree before it exits:

      {
        "verdict": "approve" | "reject",
        "run_id": "<HARNESS_RUN_ID>",
        "review_attempt": "<HARNESS_REVIEW_ATTEMPT>",
        "report": "what was found, what was fixed, why the decision",
        "checks": {"mix check.dispatch": {"passed": true, "output": "..."}},
        "concerns": [],
        "proposed_tasks": [{"title": "...", "body": "...", "suggested_scores": {}, "suggested_markers": [], "evidence": "..."}],
        "facets": {"language": "elixir", "surface": "otp", "archetype": "feature", ...},
        "skills": {"otp": {"score": 8, "note": "..."}, "concurrency": {"score": 7, "note": "..."}, ...}
      }

  ## Routing key + value (Task 224)

  `facets` is the routing KEY: an open-vocabulary, ground-truth characterization
  of what the task ACTUALLY was, written by the reviewer from the task spec + the
  real diff (language, surface, archetype, difficulty, risk, ...). It supersedes
  the sparse, optional, human-assigned `domains` tag as the grouping key.

  `skills` is the richer routing VALUE that replaces the flat `ratings`: a
  two-axis rubric (programming domains × cross-cutting qualities), each a
  `{score, note}` map, assessed only for the skills the diff actually exercised.
  Both blocks are free-form (open vocabulary, never a closed enum) and persisted
  verbatim as raw facts an AI synthesizes capability from later — harness never
  fuses them into a number.

  Legacy flat `ratings` is still parsed for back-compat with artifacts written
  before this change.

  `checks` and `concerns` are the reviewer's structured self-claim about what it
  ran and any caveats it is approving with. Harness preserves both verbatim and
  only counts reviewer-written facts: non-empty concerns or a check with
  `"passed": false` on an approve become a loud warning, never an auto-block.

  Harness never interprets the work itself — it only reads this file. An
  unreadable artifact (missing or malformed) is re-prompted once in the same
  worktree before failing as `{:review_stuck, ...}` on a second miss (Task 203
  generalized by Task 228, `Harness.Run`); the gate cannot pass silently. A
  readable verdict whose `run_id` / `review_attempt` do not match this
  invocation is treated as missing (Task 393) — the file is fenced to the
  reviewer that wrote it. The artifact lives under `.harness/`, which
  `Harness.Worktree.commit/2` excludes from staging, so it never rides in the
  deliverable commit.
  """

  alias Harness.Artifact

  @artifact_path ".harness/review.json"
  @run_id_env "HARNESS_RUN_ID"
  @review_attempt_env "HARNESS_REVIEW_ATTEMPT"

  @enforce_keys [:verdict, :report]
  defstruct [
    :verdict,
    :report,
    facets: %{},
    skills: %{},
    checks: %{},
    concerns: [],
    proposed_tasks: [],
    ratings: %{},
    task_outcomes: %{}
  ]

  @typedoc "The reviewer's decision."
  @type verdict :: :approve | :reject

  @typedoc """
  A parsed verdict artifact.

    * `verdict` — `:approve` settles the run `:done`; `:reject` settles `:failed`.
    * `report` — the reviewer's prose: what it found, fixed, and why it decided.
    * `facets` — the routing KEY: free-form ground-truth characterization of what
      the task actually was, read from the spec + the real diff. Open vocabulary.
    * `skills` — the routing VALUE: free-form two-axis rubric (domains × qualities)
      of `{score, note}` maps for the skills the diff exercised. Open vocabulary.
    * `checks` — free-form command claims keyed by command name, including the
      reviewer's own boolean pass/fail claim when supplied.
    * `concerns` — free-form list of caveats the reviewer is explicitly approving with.
    * `proposed_tasks` — free-form discovery proposals for the orchestrator to
      dedupe and file after the run lands. Each proposal names its title, body,
      suggested scores/markers, and evidence.
    * `ratings` — legacy flat implementer KPI scores, kept for back-compat with
      artifacts written before the `skills` rubric. Persisted verbatim.

  Free-form map blocks default to `%{}` and `concerns` defaults to `[]` when
  the reviewer omits them.
  """
  @type t :: %__MODULE__{
          verdict: verdict(),
          report: String.t(),
          facets: %{optional(String.t()) => term()},
          skills: %{optional(String.t()) => term()},
          checks: %{optional(String.t()) => term()},
          concerns: [term()],
          proposed_tasks: [term()],
          ratings: %{optional(String.t()) => term()},
          task_outcomes: %{optional(String.t()) => term()}
        }

  @typedoc "Why an artifact could not be read."
  @type error :: :missing | {:malformed, term()}

  @typedoc "Run identity the current reviewer invocation must echo into the artifact."
  @type identity :: %{run_id: String.t(), review_attempt: String.t()}

  @doc "Relative path of the verdict artifact inside a run worktree."
  @spec artifact_path() :: String.t()
  def artifact_path, do: @artifact_path

  @doc "Port env var carrying the run id the reviewer must echo into the artifact."
  @spec run_id_env() :: String.t()
  def run_id_env, do: @run_id_env

  @doc "Port env var carrying the review-attempt number the reviewer must echo into the artifact."
  @spec review_attempt_env() :: String.t()
  def review_attempt_env, do: @review_attempt_env

  @doc "Builds the identity map a later `read/2` compares against the artifact."
  @spec identity(String.t(), String.t() | integer()) :: identity()
  def identity(run_id, attempt) when is_binary(run_id) do
    %{run_id: run_id, review_attempt: to_string(attempt)}
  end

  @doc """
  Removes the verdict artifact at `worktree_path` if it is present.

  Called immediately before every reviewer spawn so a later `read/2` cannot
  return a prior attempt's file.
  """
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(worktree_path) when is_binary(worktree_path) do
    Artifact.remove(worktree_path, @artifact_path)
  end

  @doc """
  Reads and parses the reviewer's verdict artifact from `worktree_path`.

  `identity` is the run id and review-attempt number this invocation handed the
  reviewer. A readable approve/reject whose echoed identity does not match is
  treated as `{:error, :missing}` — same as the reviewer writing nothing — so
  the existing re-prompt/rotation ladder runs instead of settling the run.

  Returns `{:error, :missing}` when the reviewer never wrote the file, or
  `{:error, {:malformed, detail}}` when it is not valid verdict JSON.
  """
  @spec read(String.t(), identity()) :: {:ok, t()} | {:error, error()}
  def read(worktree_path, %{run_id: run_id, review_attempt: attempt} = _identity)
      when is_binary(worktree_path) and is_binary(run_id) and is_binary(attempt) do
    with {:ok, contents} <- Artifact.read(worktree_path, @artifact_path),
         {:ok, review} <- parse(contents),
         :ok <- match_identity(contents, run_id, attempt) do
      {:ok, review}
    end
  end

  @doc """
  Parses verdict-artifact JSON contents.

  ## Examples

      iex> {:ok, review} = Harness.Run.Review.parse(~s({"verdict": "approve", "report": "clean"}))
      iex> {review.verdict, review.report}
      {:approve, "clean"}
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, {:malformed, term()}}
  def parse(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"verdict" => verdict} = decoded} -> build(verdict, decoded)
      {:ok, other} -> {:error, {:malformed, {:missing_verdict, other}}}
      {:error, reason} -> {:error, {:malformed, {:invalid_json, reason}}}
    end
  end

  @doc """
  Returns true when an approving review carries reviewer-written warning facts.
  """
  @spec warning?(t() | nil) :: boolean()
  def warning?(%__MODULE__{verdict: :approve, concerns: concerns}) when concerns != [], do: true
  def warning?(%__MODULE__{verdict: :approve, checks: checks}), do: failed_check?(checks)
  def warning?(_review), do: false

  @spec build(term(), map()) :: {:ok, t()} | {:error, {:malformed, term()}}
  defp build("approve", decoded), do: {:ok, struct_for(:approve, decoded)}
  defp build("reject", decoded), do: {:ok, struct_for(:reject, decoded)}
  defp build(other, _decoded), do: {:error, {:malformed, {:invalid_verdict, other}}}

  @spec struct_for(verdict(), map()) :: t()
  defp struct_for(verdict, decoded) do
    %__MODULE__{
      verdict: verdict,
      report: report(decoded),
      facets: free_form_block(decoded, "facets"),
      skills: free_form_block(decoded, "skills"),
      checks: free_form_block(decoded, "checks"),
      concerns: free_form_list(decoded, "concerns"),
      proposed_tasks: free_form_list(decoded, "proposed_tasks"),
      ratings: free_form_block(decoded, "ratings"),
      task_outcomes: free_form_block(decoded, "task_outcomes")
    }
  end

  @spec report(map()) :: String.t()
  defp report(%{"report" => report}) when is_binary(report), do: report
  defp report(_decoded), do: ""

  # Free-form blocks (facets / skills / ratings) are persisted verbatim: keys and
  # values are the reviewer's, never validated against a closed enum. A missing or
  # non-map block parses to %{} — never a crash.
  @spec free_form_block(map(), String.t()) :: %{optional(String.t()) => term()}
  defp free_form_block(decoded, key) do
    case Map.get(decoded, key) do
      block when is_map(block) -> block
      _absent_or_non_map -> %{}
    end
  end

  @spec free_form_list(map(), String.t()) :: [term()]
  defp free_form_list(decoded, key) do
    case Map.get(decoded, key) do
      block when is_list(block) -> block
      _absent_or_non_list -> []
    end
  end

  @spec failed_check?(term()) :: boolean()
  defp failed_check?(%{"passed" => false}), do: true
  defp failed_check?(%{passed: false}), do: true
  defp failed_check?(map) when is_map(map), do: Enum.any?(map, fn {_k, v} -> failed_check?(v) end)
  defp failed_check?(list) when is_list(list), do: Enum.any?(list, &failed_check?/1)
  defp failed_check?(_other), do: false

  # Identity mismatch is absence, not malformation: the existing re-prompt /
  # rotation ladder already handles `{:error, :missing}`. Two strings compared
  # as strings; a missing field is a mismatch.
  @spec match_identity(binary(), String.t(), String.t()) :: :ok | {:error, :missing}
  defp match_identity(contents, run_id, attempt) do
    case Jason.decode(contents) do
      {:ok, decoded} when is_map(decoded) ->
        if identity_string(decoded, "run_id") == run_id and
             identity_string(decoded, "review_attempt") == attempt do
          :ok
        else
          {:error, :missing}
        end

      _other ->
        {:error, :missing}
    end
  end

  @spec identity_string(map(), String.t()) :: String.t() | nil
  defp identity_string(decoded, key) do
    case Map.get(decoded, key) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _other -> nil
    end
  end
end
