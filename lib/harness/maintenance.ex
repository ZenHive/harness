defmodule Harness.Maintenance do
  @moduledoc "Opt-in repository maintenance: isolated AI assessment and durable task publication."
  use Descripex, namespace: "/maintenance"

  alias Harness.Insights.Selection
  alias Harness.Maintenance.Pass
  alias Harness.Maintenance.Publication
  alias Harness.Maintenance.Queue
  alias Harness.Maintenance.Recovery
  alias Harness.Maintenance.Store
  alias Harness.ProjectRegistry

  @defaults %{
    "enabled" => false,
    "cadence_minutes" => 10_080,
    "agent" => "codex",
    "model" => nil,
    "deadline_seconds" => 1800
  }

  @doc "Returns saved pins without adopting changes to standing models."
  @spec settings(String.t()) :: map()
  def settings(project), do: Map.merge(@defaults, Store.get("settings/" <> project) || %{})

  api(:configure, "Configure opt-in maintenance for one registered repository; pins never change automatically.",
    params: [
      project: [kind: :value, description: "Registered project."],
      enabled: [kind: :value, description: "Enable scheduled maintenance."],
      cadence_minutes: [kind: :value, description: "60..525600 minutes; weekly is 10080."],
      agent: [kind: :value, description: "Read-only analyst: codex."],
      model: [kind: :value, description: "Explicit available model id."],
      deadline_seconds: [kind: :value, default: 1800, description: "60..3600 seconds per repository."]
    ],
    returns: %{type: :tuple, description: ":ok or {:error, reason}."}
  )

  @spec configure(String.t(), boolean(), integer(), String.t(), String.t() | nil, integer()) :: :ok | {:error, term()}
  def configure(project, enabled, cadence_minutes, agent, model, deadline_seconds \\ 1800)

  def configure(project, enabled, cadence, "codex" = agent, model, deadline)
      when is_binary(project) and is_boolean(enabled) and cadence in 60..525_600 and deadline in 60..3600 do
    config = %{
      "enabled" => enabled,
      "cadence_minutes" => cadence,
      "agent" => agent,
      "model" => model,
      "deadline_seconds" => deadline
    }

    with {:ok, _} <- ProjectRegistry.lookup(project),
         :ok <- if(enabled, do: Selection.validate(config), else: :ok),
         :ok <- Store.put_many([{"settings/" <> project, "settings", config}]) do
      broadcast()
    end
  end

  def configure(_, _, _, _, _, _), do: {:error, :invalid_settings}

  api(:status, "Bounded maintenance state, last result, next sweep and persistence mode.",
    params: [project: [kind: :value, description: "Registered project."]],
    returns: %{type: :map, description: "Settings and current progress."}
  )

  @spec status(String.t()) :: map()
  def status(project) do
    Recovery.reconcile(project)
    config = settings(project)
    progress = Store.get("progress/" <> project) || %{}

    next =
      case progress["attempted_at"] || progress["at"] do
        nil ->
          DateTime.utc_now()

        at ->
          {:ok, date, _} = DateTime.from_iso8601(at)
          DateTime.shift(date, minute: config["cadence_minutes"])
      end

    %{
      "project" => project,
      "settings" => config,
      "progress" => progress,
      "state" => if(config["enabled"], do: progress["state"] || "ready", else: "disabled"),
      "next_sweep" => if(config["enabled"], do: DateTime.to_iso8601(next)),
      "tasks" => tasks(project),
      "ephemeral" => not Store.persistent?()
    }
  end

  api(:tasks, "List up to 50 maintenance tasks from the current local roadmap; unknown state is explicit.",
    params: [project: [kind: :value, description: "Registered project."]],
    returns: %{type: :map, description: "Task page or an unavailable error."}
  )

  @spec tasks(String.t()) :: map()
  def tasks(project) do
    case Harness.Roadmap.list(project) do
      {:ok, tasks} ->
        selected = Enum.filter(tasks, &Publication.maintenance_task?(&1, project))

        Map.put(outstanding(selected, project), "items", Enum.take(selected, 50))

      {:error, _} ->
        %{"items" => [], "outstanding" => nil, "error" => "roadmap_unavailable"}
    end
  end

  @spec outstanding([map()], String.t()) :: map()
  defp outstanding(tasks, project) do
    case Publication.unfinished_count(tasks, project) do
      {:ok, count} -> %{"outstanding" => count, "error" => nil}
      {:error, reason} -> %{"outstanding" => nil, "error" => to_string(reason)}
    end
  end

  api(:sweep_now, "Queue one enabled repository; concurrent triggers share a job and pass identity.",
    params: [project: [kind: :value, description: "Registered project."]],
    returns: %{type: :tuple, description: "{:ok, job_id} or {:error, reason}."}
  )

  @spec sweep_now(String.t()) :: {:ok, term()} | {:error, term()}
  def sweep_now(project) do
    with {:ok, _} <- ProjectRegistry.lookup(project),
         true <- settings(project)["enabled"] || {:error, :disabled},
         true <- Store.persistent?() || {:error, :ephemeral_scheduler_unavailable} do
      Queue.enqueue(project)
    end
  end

  api(:findings, "List up to 50 retained findings for a repository.",
    params: [
      project: [kind: :value, description: "Project name."],
      offset: [kind: :value, default: 0, description: "Nonnegative offset."]
    ],
    returns: %{type: :map, description: "Findings and next offset."}
  )

  @spec findings(String.t(), non_neg_integer()) :: map()
  def findings(project, offset \\ 0) when is_integer(offset) and offset >= 0 do
    items = Store.list("finding/" <> project, offset, 50)
    %{"items" => items, "next_offset" => if(Enum.count_until(items, 50) == 50, do: offset + 50)}
  end

  api(:history, "Read a finding and a chronological page of assessment revisions.",
    params: [
      id: [kind: :value, description: "Finding id."],
      offset: [kind: :value, default: 0, description: "Nonnegative offset."]
    ],
    returns: %{type: :map, description: "Finding and assessment history."}
  )

  @spec history(String.t(), non_neg_integer()) :: map()
  def history(id, offset \\ 0) when is_integer(offset) and offset >= 0 do
    items = Store.list("revision/" <> id, offset, 50)

    %{
      "finding" => Store.get("finding/" <> id),
      "revisions" => Enum.reverse(items),
      "next_offset" => if(Enum.count_until(items, 50) == 50, do: offset + 50)
    }
  end

  @doc "Runs a stable pass identity; completed passes are idempotent."
  @spec sweep(String.t(), String.t()) :: :ok | {:error, term()}
  def sweep(project, id) do
    Store.serialized(fn ->
      pass = Store.get("pass/" <> id)

      cond do
        not settings(project)["enabled"] -> {:error, :disabled}
        is_map(pass) and pass["project"] != project -> {:error, :pass_project_mismatch}
        match?(%{"committed" => true}, pass) -> :ok
        true -> Pass.run(project, id, settings(project))
      end
    end)
  end

  @doc false
  @spec progress(String.t(), map()) :: :ok | {:error, term()}
  def progress(project, pass) do
    with :ok <- Store.put_many([{"progress/" <> project, "progress", pass}]), do: broadcast()
  end

  @doc "Subscribes to maintenance changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, "harness:maintenance")

  @spec broadcast() :: :ok
  defp broadcast, do: Phoenix.PubSub.broadcast(Harness.PubSub, "harness:maintenance", :maintenance_updated)
end
