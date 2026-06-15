# Orchestrator push sink — design spike (Task 290)

Status: **decision recorded, not yet built.** This spike picks the transport, the
`:settled` witness event, and sketches the reference sink so the follow-up build
(Task 294) is mechanical. Sibling pull-only path: Task 289 (`dispatch-await_runs`).

## Problem

An orchestrator driving harness over MCP/chat can fire many runs (`dispatch-task` × N,
`dispatch-bundle`) and walk away. Today it must **poll** (`dispatch-status` in a loop, or
hold one blocking `dispatch-await` per run). `Harness.Notification` already fans witness
events to configured sinks, but:

1. **No sink reaches the driving session.** `CommandSink` execs an operator script with
   flattened env vars — useful for ntfy/Slack/desktop, but an MCP client has no inbound
   channel unless the operator wires a custom listener.
2. **Events fire too late and too narrowly for “run done”.** Merge-train sinks fire on
   `:landed` / `:blocked` (and a few dispatch-gate types). The orchestrator-wakeup case
   needs notification when the **run gen_statem settles** — reviewer approved, rejected,
   failed, timed out — which may be minutes before (or instead of) a land.

Pull-only `dispatch-await_runs` (Task 289) is the 80/20 fix when the orchestrator can
hold a blocking tool call. Push is the complement: fire-and-forget dispatch, wake when
any run in the set completes.

## Decision summary

| Question | Decision |
|---|---|
| Push transport | **Append-only JSONL file** (`Harness.Notification.FileSink`) |
| New event type | **Yes — add `:settled`** beside existing merge-train / gate events |
| Fire site | `Harness.Run.settle/2` immediately after persist + `RunFeed.broadcast_settled/1` |
| Payload shape | Same compact map as `dispatch-await` (`Harness.Dispatch` summarize projection) |
| Follow-up | Task 294 — implement `:settled` + `FileSink` + tests |

---

## Transport alternatives

### Chosen: JSONL file-drop (`FileSink`)

Harness appends one JSON object per line to a configured path (default
`~/.harness/settled.jsonl`). The driving orchestrator (or a tiny sidecar) tails the file
— `tail -f`, periodic read with byte offset, or `fsnotify` — and parses new lines.

**Why this wins for the primary consumer (MCP/chat orchestrator):**

- **Survives driver restart.** Events accumulate on disk; a restarted session replays from
  its last offset. Webhooks and OS notifiers do not buffer missed deliveries.
- **Zero inbound setup on the harness node.** No port bind, no “start listener before
  dispatch” ordering constraint. The BEAM process only writes.
- **Structured payload.** Nested `review` / `reason` fields stay intact (unlike
  `CommandSink` env flattening).
- **Fast enough for inline fan-out.** A single `File.write!/3` append with `:append` mode
  is microseconds — acceptable on the run settle hot path (same failure-isolation contract
  as today’s `Notification.notify/1`).
- **Inspectable.** Operators can `tail -f` the same file humans and agents read.
- **Portable.** macOS and Linux, no `terminal-notifier` / `notify-send` dependency.

**Tradeoffs accepted:**

- Not instantaneous sub-ms (tail/poll latency). Good enough vs multi-minute runs.
- Single-writer file — fine for one harness node; multi-node would need object storage
  (out of scope until federation is real).

### Rejected: HTTP webhook to a local listener

Harness POSTs JSON to `http://127.0.0.1:<port>/harness/events`.

Rejected because the orchestrator must **pre-start** a listener before every
fire-and-forget batch, handle port conflicts, and **lose events** when the listener is
down. Durable webhook delivery implies a spool — which is the file-drop pattern with extra
steps. Keep webhooks as a **CommandSink recipe** (`curl -d @- …`) for operators who
want them; not the reference sink.

### Rejected: OS notifier (`terminal-notifier`, `notify-send`)

Rejected for orchestrator-wakeup: notifications are human-glance affordances, not a
structured `{run_id, state, review}` contract an agent can parse reliably. Already
coverable via `CommandSink` for operators who want a desktop ping **in addition** to
the JSONL feed.

### Rejected: “Just extend CommandSink”

`CommandSink` remains the generic escape hatch (ntfy, Slack, shell glue). It is not the
reference transport because:

- Env vars flatten nested maps (`review.ratings`, etc.).
- No durable default contract — every operator invents a script.
- Does not solve “driver has no inbound channel” unless the script writes the same file
  the spike specifies anyway.

---

## `:settled` witness event

### Decision: **add `:settled`** (do not overload `:landed`)

| Event | Fires when | Consumer intent |
|---|---|---|
| `:settled` | Run gen_statem enters terminal `:done` or `:failed` | “Implement + review finished” — orchestrator wakeup |
| `:landed` | Merge train ff-push succeeded | Operator witness: work is on `target_branch` |
| `:blocked` | Landing cap / conflict retained | Operator witness: train stopped |

A reviewer-approved run emits `:settled` first; `:landed` may follow minutes later on the
serialized landing queue. Reject and failure paths emit `:settled` only. **Do not** fold
settle into `:landed` — that would silence wakeup on reject/fail/timeout and conflate
review gate with merge train.

### Fire site

`Harness.Run.settle/2` after `persist_run_record/2` and `RunFeed.broadcast_settled/1`:

```elixir
Notification.notify(%Event{
  type: :settled,
  task_id: to_string(data.item.id),
  run_id: data.run_id,
  project: data.project.name,
  branch: branch_or_nil(data),
  land_attempt: data.land_attempt,
  outcome: Dispatch.summarize_result(result)  # shared helper — see below
})
```

Extract a **public** `Harness.Dispatch.summarize_result/1` (or move summarize to a tiny
shared module) so the notification payload and `dispatch-await` stay byte-identical —
no second projection to drift.

### `Event` changes

- Add `:settled` to `@type type` in `Harness.Notification.Event`.
- Document `outcome` for `:settled`: the compact settle map (see payload below).
- Add `Event.summary/1` clause, e.g. `"settled run #{run_id} task #{id}: #{state}/#{reason}"`.

### Out of scope for `:settled`

- Landing outcomes (`:landed`, `:blocked`, `:conflict`) — unchanged, still lander-only.
- In-run `:in_run_discernment`, `:dispatch_parked`, `:model_unavailable` — unchanged.

---

## Reference sink: `Harness.Notification.FileSink`

Read-only by construction — same `Sink` behaviour, no merge affordance.

### Configuration

```elixir
config :harness, Harness.Notification.FileSink,
  path: Path.expand("~/.harness/settled.jsonl")  # required to enable; absent => no-op
```

Optional follow-ups (not required for v1): `max_bytes` rotation, `fsync: true` for crash
durability vs speed.

Register beside `CommandSink`:

```elixir
config :harness, :notification_sinks, [
  Harness.Notification.CommandSink,
  Harness.Notification.FileSink
]
```

### Delivery

```elixir
defmodule Harness.Notification.FileSink do
  @behaviour Harness.Notification.Sink

  def notify(%Event{} = event) do
    case path_config() do
      nil -> :ok
      path -> append(path, envelope(event))
    end
  end

  defp envelope(%Event{} = event) do
    %{
      ts: DateTime.utc_now() |> DateTime.to_iso8601(),
      type: event.type,
      task_id: event.task_id,
      run_id: event.run_id,
      project: event.project,
      branch: event.branch,
      land_attempt: event.land_attempt,
      outcome: event.outcome,
      summary: Event.summary(event)
    }
  end

  defp append(path, map) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(map) <> "\n", [:append])
    :ok
  rescue
    error ->
      Logger.error("harness notify: FileSink append failed: #{inspect(error)}")
      :ok
  end
end
```

### Payload shape (for `:settled`)

One JSON line — mirror `dispatch-await` success body:

```json
{
  "ts": "2026-06-15T12:34:56.789Z",
  "type": "settled",
  "task_id": "42",
  "run_id": "run-1781487644448-abc",
  "project": "harness",
  "branch": "harness/run-1781487644448-abc",
  "land_attempt": 1,
  "summary": "settled run run-1781487644448-abc task 42: done/approved",
  "outcome": {
    "run_id": "run-1781487644448-abc",
    "task_id": "42",
    "state": "done",
    "reason": "approved",
    "passed": true,
    "agent_diff_size": 120,
    "reviewer_diff_size": 0,
    "worktree_path": "/path/to/worktree",
    "review": {
      "verdict": "approve",
      "report": "...",
      "ratings": { "performance": 4, "truthfulness": 5, "code_quality": 4, "idiom_usage": 4 }
    }
  }
}
```

For `:failed` settles, `state` is `"failed"`, `passed` is `false`, `reason` carries
`:reject`, `:timed_out`, etc. (same atoms/strings as `%Run.Result{}` today).

Non-`:settled` events (if ever written to the same file) use their existing `outcome`
shapes; the envelope is uniform.

### Failure isolation

Unchanged contract from `Harness.Notification`:

- Dispatcher rescues per sink; a broken `FileSink` never fails the run settle.
- `FileSink` rescues locally and logs — never raises into the dispatcher.
- Sink must return `:ok` promptly (append only — no network, no LLM).

### Driver integration (documented, not built in harness)

Orchestrator-side pattern (playbook / harness-driver skill addition in Task 294):

1. Record `File.byte_size(path)` (or last line count) before dispatching N runs.
2. On idle / scheduled wake, read appended lines, `Jason.decode!/1` each.
3. Filter `type == "settled"` and `run_id in @watch_set`.
4. Act using embedded `outcome` or call `dispatch-status` for freshness.
5. Optionally call `dispatch-await_runs` for any still-missing ids (push + pull hybrid).

---

## Relationship to existing tools

| Mechanism | Direction | When |
|---|---|---|
| `dispatch-await` | Pull, blocking, one run | Orchestrator dispatches and waits in one tool call |
| `dispatch-await_runs` (289) | Pull, blocking, N runs | Same session holds connection until all settle or timeout |
| `FileSink` + `:settled` (294) | Push, durable | Fire-and-forget batch; driver tails JSONL between other work |
| `CommandSink` | Push, ephemeral | Operator scripts (ntfy, Slack, desktop) — any event type |

Push does not replace pull — an orchestrator can tail JSONL **and** use
`dispatch-await_runs` as a backstop when it returns to the harness tools.

---

## Follow-up build

**Task 294** — `Settled witness event + FileSink for orchestrator wakeup` (`depends_on`
290). See `roadmap/tasks.toml`.
