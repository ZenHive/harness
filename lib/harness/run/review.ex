defmodule Harness.Run.Review do
  @moduledoc """
  The reviewer AI's verdict artifact — `.harness/review.json` — read mechanically.

  The cross-family reviewer is THE gate of the agent-gate workflow: it reviews
  the implementer's work, runs the project's checks itself, fixes inline, and
  writes this file in the run worktree before it exits:

      {
        "verdict": "approve" | "reject",
        "report": "what was found, what was fixed, why the decision",
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

  Harness never interprets the work itself — it only reads this file. A
  malformed artifact settles the run `:failed` (`{:review_stuck, ...}`); a
  missing artifact is re-prompted once before failing the same way (Task 203,
  `Harness.Run`); the gate cannot pass silently. The artifact lives under
  `.harness/`, which
  `Harness.Worktree.commit/2` excludes from staging, so it never rides in the
  deliverable commit.
  """

  @artifact_path ".harness/review.json"

  @enforce_keys [:verdict, :report]
  defstruct [:verdict, :report, facets: %{}, skills: %{}, ratings: %{}]

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
    * `ratings` — legacy flat implementer KPI scores, kept for back-compat with
      artifacts written before the `skills` rubric. Persisted verbatim.

  All three free-form blocks default to `%{}` when the reviewer omits them.
  """
  @type t :: %__MODULE__{
          verdict: verdict(),
          report: String.t(),
          facets: %{optional(String.t()) => term()},
          skills: %{optional(String.t()) => term()},
          ratings: %{optional(String.t()) => term()}
        }

  @typedoc "Why an artifact could not be read."
  @type error :: :missing | {:malformed, term()}

  @doc "Relative path of the verdict artifact inside a run worktree."
  @spec artifact_path() :: String.t()
  def artifact_path, do: @artifact_path

  @doc """
  Reads and parses the reviewer's verdict artifact from `worktree_path`.

  Returns `{:error, :missing}` when the reviewer never wrote the file, or
  `{:error, {:malformed, detail}}` when it is not valid verdict JSON.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, error()}
  # sobelow_skip ["Traversal.FileModule"]
  # worktree_path is harness-generated (Harness.Worktree.create/2), never user input.
  def read(worktree_path) when is_binary(worktree_path) do
    case File.read(Path.join(worktree_path, @artifact_path)) do
      {:ok, contents} -> parse(contents)
      {:error, :enoent} -> {:error, :missing}
      {:error, reason} -> {:error, {:malformed, {:unreadable, reason}}}
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
      ratings: free_form_block(decoded, "ratings")
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
end
