defmodule Harness.Run.Review do
  @moduledoc """
  The reviewer AI's verdict artifact — `.harness/review.json` — read mechanically.

  The cross-family reviewer is THE gate of the agent-gate workflow: it reviews
  the implementer's work, runs the project's checks itself, fixes inline, and
  writes this file in the run worktree before it exits:

      {
        "verdict": "approve" | "reject",
        "report": "what was found, what was fixed, why the decision",
        "ratings": {"performance": 8, "truthfulness": 9, "code_quality": 7, "idiom": 8}
      }

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
  defstruct [:verdict, :report, ratings: %{}]

  @typedoc "The reviewer's decision."
  @type verdict :: :approve | :reject

  @typedoc """
  A parsed verdict artifact.

    * `verdict` — `:approve` settles the run `:done`; `:reject` settles `:failed`.
    * `report` — the reviewer's prose: what it found, fixed, and why it decided.
    * `ratings` — free-form implementer KPI scores (performance, truthfulness,
      code quality, idiom usage, ...). Keys and scales are the reviewer's; they
      are persisted verbatim and fed to `Harness.AgentKPI`.
  """
  @type t :: %__MODULE__{
          verdict: verdict(),
          report: String.t(),
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
  defp build("approve", decoded),
    do: {:ok, %__MODULE__{verdict: :approve, report: report(decoded), ratings: ratings(decoded)}}

  defp build("reject", decoded),
    do: {:ok, %__MODULE__{verdict: :reject, report: report(decoded), ratings: ratings(decoded)}}

  defp build(other, _decoded), do: {:error, {:malformed, {:invalid_verdict, other}}}

  @spec report(map()) :: String.t()
  defp report(%{"report" => report}) when is_binary(report), do: report
  defp report(_decoded), do: ""

  @spec ratings(map()) :: %{optional(String.t()) => term()}
  defp ratings(%{"ratings" => ratings}) when is_map(ratings), do: ratings
  defp ratings(_decoded), do: %{}
end
