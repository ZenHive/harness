defmodule Harness.Run.Recovery do
  @moduledoc """
  The bounded, witnessed AI-recovery seam — `.harness/recovery.json` — read mechanically.

  Tier-2 of the self-heal design (Tier-1 is mechanical retry/re-prompt/rotate,
  tasks 227/228). Before `Harness.Run` settles `:failed` for a NON-rejection
  reason that genuinely needs a situation read, it spawns a bounded cross-family
  recovery AI with MINIMAL context (the error term + the main checkout's git
  status + the implementer transcript tail + the failing-check output — never the
  full transcript). The recovery AI fixes what it can and writes this file before
  it exits:

      {
        "outcome": "repaired" | "dead",
        "report": "what the situation was, what was done, why the decision",
        "repaired": "a short note on what was repaired (omit / null when dead)"
      }

  Harness reads the artifact mechanically and decides NOTHING about
  recoverability itself: `repaired` resumes the lifecycle at a state that
  RE-RUNS the reviewer gate (never skips to `:done`); `dead`, a missing artifact,
  or a malformed artifact settles `:failed` with the original reason. The single
  initial call-site is checkout pollution — the one genuinely interpretive
  failure (gaps 1–4/6 are mechanical and handled by tasks 227/228). The seam is
  built generalizable; more call-sites can be routed through it later.

  Recovery is bounded PER-RUN by a single recovery budget (not per-failure-type),
  and a genuine `verdict: reject` is NEVER routed through it. The artifact lives
  under `.harness/`, which `Harness.Worktree.commit/2` excludes from staging, so
  it never rides in the deliverable commit.
  """

  @artifact_path ".harness/recovery.json"

  @enforce_keys [:outcome, :report]
  defstruct [:outcome, :report, repaired: nil]

  @typedoc "The recovery AI's decision."
  @type outcome :: :repaired | :dead

  @typedoc """
  A parsed recovery artifact.

    * `outcome` — `:repaired` resumes the lifecycle (re-running the reviewer
      gate); `:dead` settles the run `:failed` with the original reason.
    * `report` — the recovery AI's prose: what the situation was, what it did,
      and why it decided.
    * `repaired` — a short note on what was repaired, or `nil` when the AI
      declared the run dead.
  """
  @type t :: %__MODULE__{
          outcome: outcome(),
          report: String.t(),
          repaired: String.t() | nil
        }

  @typedoc "Why an artifact could not be read."
  @type error :: :missing | {:malformed, term()}

  @typedoc "Minimal situational context handed to the recovery AI."
  @type context :: %{
          reason: term(),
          repo_path: String.t(),
          git_status: String.t(),
          transcript_tail: String.t(),
          check_output: String.t()
        }

  @doc "Relative path of the recovery artifact inside a run worktree."
  @spec artifact_path() :: String.t()
  def artifact_path, do: @artifact_path

  @doc """
  Reads and parses the recovery AI's artifact from `worktree_path`.

  Returns `{:error, :missing}` when the AI never wrote the file, or
  `{:error, {:malformed, detail}}` when it is not valid recovery JSON.
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
  Parses recovery-artifact JSON contents.

  ## Examples

      iex> {:ok, recovery} = Harness.Run.Recovery.parse(~s({"outcome": "dead", "report": "unrecoverable"}))
      iex> {recovery.outcome, recovery.report}
      {:dead, "unrecoverable"}
  """
  @spec parse(binary()) :: {:ok, t()} | {:error, {:malformed, term()}}
  def parse(contents) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, %{"outcome" => outcome} = decoded} -> build(outcome, decoded)
      {:ok, other} -> {:error, {:malformed, {:missing_outcome, other}}}
      {:error, reason} -> {:error, {:malformed, {:invalid_json, reason}}}
    end
  end

  @doc """
  Builds the recovery AI's prompt from minimal situational context.

  Deliberately terse: the error, the checkout state, a transcript tail, and the
  failing-check output — never the full transcript. The recovery AI judges
  whether the situation is repairable and records its decision in the artifact;
  harness interprets none of it.
  """
  @spec prompt(context()) :: String.t()
  def prompt(%{} = ctx) do
    """
    You are a bounded, cross-family RECOVERY agent for a harness run that is about to be discarded.

    A non-rejection failure was detected AFTER the implementer finished, before the reviewer gate ran:
    the implementer leaked changes into the MAIN checkout instead of staying inside its isolated
    worktree. Your ONE job is to read the situation, repair it if it is genuinely repairable, then
    write your verdict to `#{@artifact_path}` and stop.

    What "repaired" means here: the main checkout (path below) is clean again — every leaked,
    non-deliverable change reverted or moved into the worktree — so the run can safely resume and be
    re-judged by the reviewer gate. If the leak cannot be cleanly undone, or the work is unsalvageable,
    declare it dead. When in doubt, declare dead — never claim repaired unless the checkout is actually
    clean. You are NOT the gate: a repaired run still goes back through the full cross-family review.

    Main checkout path (clean THIS, not the worktree): #{Map.get(ctx, :repo_path, "(unknown)")}
    Failure reason: #{inspect(Map.get(ctx, :reason))}

    Main checkout git status (the leak):
    #{placeholder(Map.get(ctx, :check_output))}

    Worktree git status:
    #{placeholder(Map.get(ctx, :git_status))}

    Implementer transcript tail:
    #{placeholder(Map.get(ctx, :transcript_tail))}

    Verdict artifact — write this LAST, then stop:

    #{@artifact_path}
    {
      "outcome": "repaired" | "dead",
      "report": "<what the situation was, what you did, why you decided>",
      "repaired": "<short note on what you repaired, or null when dead>"
    }

    A missing or malformed #{@artifact_path} is treated as dead and fails this run for good.
    """
  end

  @spec build(term(), map()) :: {:ok, t()} | {:error, {:malformed, term()}}
  defp build("repaired", decoded),
    do: {:ok, %__MODULE__{outcome: :repaired, report: report(decoded), repaired: repaired(decoded)}}

  defp build("dead", decoded), do: {:ok, %__MODULE__{outcome: :dead, report: report(decoded), repaired: nil}}

  defp build(other, _decoded), do: {:error, {:malformed, {:invalid_outcome, other}}}

  @spec report(map()) :: String.t()
  defp report(%{"report" => report}) when is_binary(report), do: report
  defp report(_decoded), do: ""

  @spec repaired(map()) :: String.t() | nil
  defp repaired(%{"repaired" => repaired}) when is_binary(repaired), do: repaired
  defp repaired(_decoded), do: nil

  @spec placeholder(String.t() | nil) :: String.t()
  defp placeholder(nil), do: "(none)"
  defp placeholder(""), do: "(none)"
  defp placeholder(text) when is_binary(text), do: text
end
