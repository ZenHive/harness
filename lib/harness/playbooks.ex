defmodule Harness.Playbooks do
  @moduledoc """
  Orchestration playbooks: ready-to-run recipes the chat/MCP orchestrator follows.

  A playbook is a markdown recipe — "dispatch a single task", "fan out a bundle",
  "A/B compare adapters", "audit-grade a fix" — written for the tool-equipped LLM
  driving harness. It names the exact MCP tools to call, in order, with the
  gotchas (secret scrubbing, adapter selection, verdict reading) inline.

  Surfaced as two tools via `Harness.Manifest` → `Harness.Chat.Tools` and the
  external MCP endpoint: `playbooks-list` returns the catalog, `playbooks-get`
  returns one playbook's full markdown body. The orchestrator calls `list` to see
  what's available, `get` to load the recipe it then executes by calling the other
  harness tools. The dashboard surfaces them as buttons that prefill the chat input.

  ## Why tools, not a normalized event model or a bespoke prompts protocol

  Playbooks are static, version-controlled markdown. Exposing them through the same
  descripex `api()` path as every other harness tool means they appear in both the
  in-process chat dispatcher and the external MCP surface from one declaration —
  no separate registry, no protocol work. Bodies live in `priv/playbooks/<name>.md`
  and are embedded at compile time (`@external_resource`), so editing a recipe is a
  markdown edit + recompile, not a code change.
  """

  use Descripex, namespace: "/playbooks"

  @typedoc "A playbook catalog entry (without its markdown body)."
  @type summary :: %{name: String.t(), title: String.t(), summary: String.t()}

  @typedoc "A full playbook: the catalog entry plus its markdown body."
  @type playbook :: %{name: String.t(), title: String.t(), summary: String.t(), body: String.t()}

  # The catalog is the source of truth for which playbooks exist and their
  # one-line descriptions; `name` doubles as the `priv/playbooks/<name>.md`
  # filename. Adding a playbook = add an entry here + drop the markdown file.
  @catalog [
    %{
      name: "dispatch-single-task",
      title: "Dispatch a single roadmap task",
      summary:
        "Browse a project's roadmap, ingest one task, run it through an adapter in an isolated worktree, read the verified result."
    },
    %{
      name: "dispatch-bundle",
      title: "Dispatch a bundle (fan out the next session of work)",
      summary: "Fetch the next session-sized bundle and fan it out via the Oban-persisted, per-project queue."
    },
    %{
      name: "ab-adapter-compare",
      title: "A/B compare adapters on one task",
      summary: "Run one task through N adapters and compare verdict, repair effort, and diff size side by side."
    },
    %{
      name: "audit-grade-fix",
      title: "Audit-grade a fix (cross-agent HIGH-tier review)",
      summary:
        "Grade a landed diff with the opposite agent via the APPROVE/REJECT sentinel, enforcing evaluator separation."
    }
  ]

  @playbook_names Enum.map(@catalog, & &1.name)

  for name <- @playbook_names do
    @external_resource Path.join([__DIR__, "..", "..", "priv", "playbooks", "#{name}.md"])
  end

  @bodies Map.new(@playbook_names, fn name ->
            {name, File.read!(Path.join([__DIR__, "..", "..", "priv", "playbooks", "#{name}.md"]))}
          end)

  api(:list, "List the orchestration playbooks available to run via the harness chat/MCP surface.",
    returns: %{
      type: :list,
      description:
        "[%{name, title, summary}] — `name` is the slug to pass to playbooks-get; `title`/`summary` describe each playbook. Static catalog; cannot fail."
    }
  )

  @spec list() :: [summary()]
  def list, do: @catalog

  api(:get, "Fetch the full markdown body of one orchestration playbook by name.",
    params: [
      name: [
        kind: :value,
        description: "Playbook slug from playbooks-list (e.g. \"dispatch-single-task\")."
      ]
    ],
    returns: %{
      type: :tuple,
      description:
        "{:ok, %{name, title, summary, body}} with the full markdown recipe. {:error, {:unknown_playbook, name}} if the slug is not in the catalog."
    }
  )

  @spec get(String.t()) :: {:ok, playbook()} | {:error, {:unknown_playbook, String.t()}}
  def get(name) when is_binary(name) do
    case Enum.find(@catalog, &(&1.name == name)) do
      nil -> {:error, {:unknown_playbook, name}}
      entry -> {:ok, Map.put(entry, :body, Map.fetch!(@bodies, name))}
    end
  end
end
