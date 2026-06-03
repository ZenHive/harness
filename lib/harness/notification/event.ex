defmodule Harness.Notification.Event do
  @moduledoc """
  A merge-train lifecycle event handed to notification sinks.

  Fired by `Harness.Lander.Resilience` when a run **lands** or a task is
  **blocked** (landing-attempt cap exhausted), and by `Harness.Run` when in-run
  discernment samples a partial transcript.

  ## The sakshi↔buddhi hinge

  The struct is deliberately *lossless*. A passive (sakshi) sink — e.g.
  `Harness.Notification.CommandSink` — flattens it to a one-line `summary/1` for a
  human glance. A discerning (buddhi) sink consumes the struct natively: `outcome`
  carries the *raw* payload (the landed SHA, the structured reason, or the sampled
  discernment payload), so a triage agent can reason about it and act **through**
  the train — enqueue a fresh run — rather than around it. That asymmetry is the
  whole point: the witness can have judgment, but the only affordance it is handed
  is data, never a merge.
  """

  @typedoc "Which merge-train transition fired."
  @type type :: :landed | :blocked | :in_run_discernment

  @typedoc """
  The raw outcome payload, keyed by `type`:

    * `:landed` — the landed commit SHA (`String.t()`).
    * `:blocked` — the structured blocked reason (`String.t()`).
    * `:in_run_discernment` — a sampled partial-transcript reviewer payload.
  """
  @type outcome :: String.t() | map()

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

  def summary(%__MODULE__{type: :in_run_discernment, task_id: id, outcome: %{action: action, verdict: verdict}}),
    do: "in-run discernment on task #{id}: #{action} (#{verdict})"
end
