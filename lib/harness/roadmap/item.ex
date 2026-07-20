defmodule Harness.Roadmap.Item do
  @moduledoc """
  A roadmap task fetched and rendered for dispatch.

  Produced by `Harness.Roadmap.ingest/2` — the input half of a run. An `Item`
  carries the task's identity plus a ready-to-run agent prompt; it is
  deliberately *not* a `Harness.AgentAdapter.Invocation`, because an invocation
  also needs the isolated worktree `cwd`, which the run-lifecycle process
  supplies. Named `Item` rather than `Task` so it never shadows the stdlib
  `Task` module.
  """

  alias Harness.AgentRegistry
  alias Harness.CapabilityDomain

  @typedoc """
  An ingested roadmap task.

    * `id` — the rmap task id, a string (e.g. `"6"`).
    * `title` — the task's one-line title, for logging.
    * `prompt` — the task rendered as an agent prompt: the raw, verbatim output
      of `rmap delegate`, passed through untouched.
    * `agent` — the agent the prompt was rendered for. A prompt rendered for one
      agent is not interchangeable with another, so the pairing is carried.
    * `assignee` — the task's roadmap-pinned dispatch agent (the operator's routing
      intent at scoping time), or `nil` when the task carries no pin (or pins a
      non-executable assignee like `human`). Distinct from `agent`: `agent` is who
      the *prompt* was rendered for, `assignee` is who the task *should run on*. The
      recommend path honors this pin over the global `dispatch.default_agent` so an
      explicit assignee always wins; capability scoring/default only fill the gap
      when it is `nil`.
    * `body` — the task's original `body` field (intent at scoping time), or
      `nil` when the task carries none. The rendered `prompt` already embeds the
      body, but it's carried structurally so the semantic gate and any triage
      agent can read the task's contract without re-parsing the prompt.
    * `acceptance_criteria` — the task's structured acceptance criteria as a list
      of strings; an empty list when the task declares none.
    * `domains` — advisory capability-domain tags copied onto run records at
      settle time; empty for untagged production tasks and historical ingests.
    * `d` — the task's structured rmap difficulty score (`scores.d`), or `nil`
      when the task carries no score. Carried as a typed field so the in-run
      discernment stakes gate reads it directly instead of scraping `D:X` out of
      the rendered prompt text.
    * `markers` — the task's rmap markers as atoms (e.g. `:security`, `:bug`,
      `:parallel`); an empty list when the task declares none. Carried so the
      stakes gate matches the typed `:security` / `:bug` markers instead of
      keyword-matching prose (which misses CVE/exploit/auth-bypass and
      false-positives on "fixed a bug").
    * `model` — the task's pinned `model` field from rmap when present (an LLM
      id like `claude-opus-4-7`, or an agent routing token like `codex`); carried
      through dispatch as the requested model when the agent does not self-report.
    * `fingerprint` — a dispatch-time hash of stable task content. The lander
      checks it before writing `done --shipped-in` so a reused numeric id cannot
      silently mark a different task.
  """
  @type t :: %__MODULE__{
          id: String.t(),
          title: String.t(),
          prompt: String.t(),
          agent: AgentRegistry.agent(),
          assignee: AgentRegistry.agent() | nil,
          body: String.t() | nil,
          acceptance_criteria: [String.t()],
          domains: [CapabilityDomain.t()],
          d: non_neg_integer() | nil,
          markers: [atom() | String.t()],
          model: String.t() | nil,
          fingerprint: String.t() | nil,
          task_ids: [String.t()],
          task_fingerprints: %{optional(String.t()) => String.t() | nil}
        }

  @enforce_keys [:id, :title, :prompt, :agent]
  defstruct [
    :id,
    :title,
    :prompt,
    :agent,
    :body,
    :d,
    acceptance_criteria: [],
    assignee: nil,
    domains: [],
    markers: [],
    model: nil,
    fingerprint: nil,
    task_ids: [],
    task_fingerprints: %{}
  ]

  @doc false
  @spec coalesce([t()]) :: t()
  def coalesce([%__MODULE__{} = first | rest]) do
    items = [first | rest]

    %{
      first
      | title: "Coalesced tasks: " <> Enum.map_join(items, ", ", & &1.title),
        prompt: Enum.map_join(items, "\n\n---\n\n", & &1.prompt),
        body: coalesced_body(items),
        acceptance_criteria: Enum.flat_map(items, & &1.acceptance_criteria),
        domains: items |> Enum.flat_map(& &1.domains) |> Enum.uniq(),
        task_ids: Enum.map(items, & &1.id),
        task_fingerprints: Map.new(items, &{&1.id, &1.fingerprint})
    }
  end

  # `body` stays nil when no member declares one, rather than degrading to a
  # string of bare separators that reads as "there is a body" to the gate.
  @spec coalesced_body([t()]) :: String.t() | nil
  defp coalesced_body(items) do
    case Enum.reject(Enum.map(items, & &1.body), &(&1 in [nil, ""])) do
      [] -> nil
      bodies -> Enum.join(bodies, "\n\n---\n\n")
    end
  end
end
