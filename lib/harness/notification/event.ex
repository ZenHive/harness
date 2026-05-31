defmodule Harness.Notification.Event do
  @moduledoc """
  A merge-train lifecycle event handed to notification sinks.

  Fired by `Harness.Lander.Resilience` when a run **lands**, a task is **blocked**
  (landing-attempt cap exhausted), or a branch comes back **red post-merge**.

  ## The sakshi↔buddhi hinge

  The struct is deliberately *lossless*. A passive (sakshi) sink — e.g.
  `Harness.Notification.CommandSink` — flattens it to a one-line `summary/1` for a
  human glance. A discerning (buddhi) sink consumes the struct natively: `outcome`
  carries the *raw* payload (the landed SHA, the structured reason, or the failing
  `Harness.Verification.Verdict`), so a triage agent can reason about it and act
  **through** the train — enqueue a fresh verified run — rather than around it.
  That asymmetry is the whole point: the witness can have judgment, but the only
  affordance it is handed is data, never a merge.
  """

  alias Harness.Verification.Verdict

  @typedoc "Which merge-train transition fired."
  @type type :: :landed | :blocked | :post_merge_red

  @typedoc """
  The raw outcome payload, keyed by `type`:

    * `:landed` — the landed commit SHA (`String.t()`).
    * `:blocked` — the structured blocked reason (`String.t()`).
    * `:post_merge_red` — the failing `Harness.Verification.Verdict`.
  """
  @type outcome :: String.t() | Verdict.t()

  @typedoc "A merge-train lifecycle event."
  @type t :: %__MODULE__{
          type: type(),
          task_id: String.t(),
          run_id: String.t() | nil,
          project: String.t() | nil,
          branch: String.t() | nil,
          land_attempt: pos_integer(),
          outcome: outcome()
        }

  @enforce_keys [:type, :task_id]
  defstruct [:type, :task_id, :run_id, :project, :branch, :outcome, land_attempt: 1]

  @doc """
  Renders a one-line human summary of `event` — the sakshi projection.

  Lossy by design: collapses the raw `outcome` to a glanceable string for sinks
  that feed a human (ntfy / desktop / Slack). Buddhi sinks should read the struct
  fields directly, not parse this.

  ## Examples

      iex> Harness.Notification.Event.summary(%Harness.Notification.Event{
      ...>   type: :landed, task_id: "42", outcome: "abc123"
      ...> })
      "landed task 42 at abc123"

      iex> Harness.Notification.Event.summary(%Harness.Notification.Event{
      ...>   type: :blocked, task_id: "42", outcome: "land-cap exhausted"
      ...> })
      "blocked task 42: land-cap exhausted"
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{type: :landed, task_id: id, outcome: sha}), do: "landed task #{id} at #{sha}"

  def summary(%__MODULE__{type: :blocked, task_id: id, outcome: reason}), do: "blocked task #{id}: #{reason}"

  def summary(%__MODULE__{type: :post_merge_red, task_id: id, outcome: outcome}),
    do: "post-merge red on task #{id}: #{red_detail(outcome)}"

  # Names the failed checks from a Verdict; falls back to inspect for any other
  # payload so the summary never crashes on an unexpected shape.
  @spec red_detail(Verdict.t() | term()) :: String.t()
  defp red_detail(%Verdict{results: results}) when is_list(results) do
    case Enum.filter(results, &(&1.status == :fail)) do
      [] -> "no failing check recorded"
      failed -> failed |> Enum.map_join(", ", & &1.name) |> then(&"failed #{&1}")
    end
  end

  defp red_detail(other), do: inspect(other)
end
