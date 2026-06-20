defmodule Harness.Notification.Event do
  @moduledoc """
  A merge-train lifecycle event handed to notification sinks.

  Fired by `Harness.Lander.Resilience` when a run **lands**, a task is
  **blocked** (landing-attempt cap exhausted), or a manual reland retains a
  conflicted branch; by `Harness.Lander` when the operator's local target branch
  needs manual sync after a successful land; by `Harness.Run` on every terminal
  settle (`:settled` for `:done` / `:failed` runs); and by `Harness.Run` when
  in-run discernment samples a partial transcript.

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

  @typedoc "Which merge-train (or dispatch-gate) transition fired."
  @type type ::
          :landed
          | :blocked
          | :conflict
          | :local_sync_skipped
          | :in_run_discernment
          | :dispatch_parked
          | :model_unavailable
          | :settled

  @typedoc """
  The raw outcome payload, keyed by `type`:

    * `:landed` — the landed commit SHA (`String.t()`).
    * `:blocked` — the structured blocked reason (`String.t()`).
    * `:conflict` — the raw rebase conflict output for a retained manual reland.
    * `:local_sync_skipped` — the manual-sync reason (`String.t()`).
    * `:in_run_discernment` — a sampled partial-transcript reviewer payload.
    * `:dispatch_parked` — a parked autonomous-dispatch decision (`%{adapter,
      pending_id}`), fired when a `:manual`-mode project holds an enqueue for
      operator approval instead of dispatching it.
    * `:model_unavailable` — dispatch rejected a blocked `{agent, model}` pair
      (`%{agent, model, available}`).
    * `:settled` — the compact settle map from `Harness.Dispatch.summarize_result/1`
      for a terminal run (`:done` / `:failed`).
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

      iex> Harness.Notification.Event.summary(%Harness.Notification.Event{
      ...>   type: :dispatch_parked, task_id: "42", outcome: %{adapter: "claude", pending_id: "proj:42"}
      ...> })
      "parked dispatch of task 42 for claude (awaiting operator approval)"
  """
  @spec summary(t()) :: String.t()
  def summary(%__MODULE__{type: :landed, task_id: id, outcome: sha}), do: "landed task #{id} at #{sha}"

  def summary(%__MODULE__{type: :blocked, task_id: id, outcome: reason}), do: "blocked task #{id}: #{reason}"

  def summary(%__MODULE__{type: :conflict, task_id: id, outcome: output}), do: "conflict landing task #{id}: #{output}"

  def summary(%__MODULE__{type: :local_sync_skipped, task_id: id, outcome: reason}),
    do: "local sync skipped for task #{id}: #{reason}"

  def summary(%__MODULE__{type: :in_run_discernment, task_id: id, outcome: %{action: action, verdict: verdict}}),
    do: "in-run discernment on task #{id}: #{action} (#{verdict})"

  def summary(%__MODULE__{type: :dispatch_parked, task_id: id, outcome: %{adapter: adapter}}),
    do: "parked dispatch of task #{id} for #{adapter} (awaiting operator approval)"

  def summary(%__MODULE__{type: :model_unavailable, task_id: id, outcome: %{agent: agent, model: model}}),
    do: "blocked dispatch of task #{id} for #{agent}/#{model || "default"}"

  def summary(%__MODULE__{
        type: :settled,
        run_id: run_id,
        task_id: id,
        outcome: %{state: state, reason: reason} = outcome
      }), do: "settled run #{run_id} task #{id}: #{state}/#{settle_reason_label(reason)}#{review_warning_suffix(outcome)}"

  @spec settle_reason_label(atom() | tuple()) :: String.t()
  defp settle_reason_label({tag, _rest}), do: Atom.to_string(tag)
  defp settle_reason_label(reason) when is_atom(reason), do: Atom.to_string(reason)

  @spec review_warning_suffix(map()) :: String.t()
  defp review_warning_suffix(%{review_warning: true}), do: " REVIEW-WARNING"
  defp review_warning_suffix(_outcome), do: ""
end
