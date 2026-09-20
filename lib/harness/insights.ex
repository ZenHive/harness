defmodule Harness.Insights do
  @moduledoc "Independent, disabled-by-default AI observations across runs."
  use Descripex, namespace: "/insights"

  alias Harness.Insights.Evidence
  alias Harness.Insights.Publication
  alias Harness.Insights.Store
  alias Harness.Insights.Witness
  alias Harness.Insights.Worker

  @topic "harness:insights"
  @defaults %{"enabled" => false, "cadence_minutes" => 60, "agent" => "claude", "model" => "sonnet"}

  api(:status, "Bounded observation settings, last pass and durable progress; independent of dispatch autonomy.",
    returns: %{type: :map, description: "Observer status and persistence mode."}
  )

  @spec status() :: map()
  def status do
    settings = settings()
    progress = Store.get("progress") || %{}
    last = List.first(Store.list("pass", 0, 1))

    %{
      "settings" => settings,
      "progress" => progress,
      "last_pass" => last,
      "last_success" => progress["last_success"],
      "next_pass" => next_pass(settings, progress),
      "ephemeral" => not Store.persistent?(),
      "state" => if(settings["enabled"], do: (last || %{})["state"] || "ready", else: "disabled")
    }
  end

  @doc "Returns independently persisted observer settings."
  @spec settings() :: map()
  def settings, do: Map.merge(@defaults, Store.get("settings") || %{})

  @doc "Sets explicit witness configuration without changing dispatch settings."
  @spec configure(map()) :: :ok | {:error, term()}
  def configure(%{"enabled" => enabled, "cadence_minutes" => cadence, "agent" => "claude", "model" => model} = settings)
      when is_boolean(enabled) and cadence in [15, 60, 360, 1440] and is_binary(model) and byte_size(model) in 1..120 do
    result = Store.put_many([{"settings", "settings", Map.take(settings, Map.keys(@defaults))}])
    broadcast()
    result
  end

  def configure(_), do: {:error, :invalid_settings}

  api(:observe_now, "Enqueue a serialized advisory observation when enabled; never dispatches or edits repositories.",
    returns: %{type: :tuple, description: "{:ok, job_id} or {:error, reason}."}
  )

  @spec observe_now() :: {:ok, term()} | {:error, term()}
  def observe_now do
    cond do
      not settings()["enabled"] ->
        {:error, :disabled}

      not Store.persistent?() ->
        {:error, :ephemeral_scheduler_unavailable}

      true ->
        case Harness.Oban.insert(Worker.new(%{"pass_id" => Ecto.UUID.generate()})) do
          {:ok, job} -> {:ok, job.id}
          error -> error
        end
    end
  end

  api(:findings, "List up to 50 findings, newest revision first, optionally filtered by project or run.",
    params: [
      project: [kind: :value, default: "", description: "Project name or empty for all."],
      run_id: [kind: :value, default: "", description: "Run id or empty for all."],
      offset: [kind: :value, default: 0, description: "Nonnegative document offset."]
    ],
    returns: %{type: :map, description: "Bounded findings page with next_offset."}
  )

  @spec findings(String.t(), String.t(), non_neg_integer()) :: map()
  def findings(project \\ "", run_id \\ "", offset \\ 0) when is_integer(offset) and offset >= 0 do
    filters = %{}
    filters = if project == "", do: filters, else: Map.put(filters, "projects", [project])
    filters = if run_id == "", do: filters, else: Map.put(filters, "runs", [run_id])
    page = Store.list("finding", offset, 50, filters)
    %{"items" => page, "next_offset" => if(Enum.count_until(page, 50) == 50, do: offset + 50)}
  end

  api(:history, "Read a finding and up to 50 retained revisions with cited excerpts.",
    params: [
      id: [kind: :value, description: "Finding id."],
      offset: [kind: :value, default: 0, description: "Nonnegative revision offset."]
    ],
    returns: %{type: :map, description: "Finding and chronological revisions within the requested page."}
  )

  @spec history(String.t(), non_neg_integer()) :: map()
  def history(id, offset \\ 0) when is_binary(id) and is_integer(offset) and offset >= 0 do
    revisions = Store.list("revision/" <> id, offset, 50)

    %{
      "finding" => Store.get("finding/" <> id),
      "revisions" => Enum.reverse(revisions),
      "next_offset" => if(Enum.count_until(revisions, 50) == 50, do: offset + 50)
    }
  end

  @doc "Executes one idempotent pass; successful results and progress commit together."
  @spec observe(String.t()) :: :ok | {:error, term()}
  def observe(pass_id) when is_binary(pass_id) do
    result =
      Store.serialized(fn ->
        cond do
          not settings()["enabled"] -> {:error, :disabled}
          match?(%{"committed" => true}, Store.get("pass/" <> pass_id)) -> :ok
          true -> run_pass(pass_id)
        end
      end)

    broadcast()
    result
  end

  @doc "Subscribes a dashboard process to observation updates."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  @spec run_pass(String.t()) :: :ok | {:error, term()}
  defp run_pass(id) do
    config = settings()
    observer = Map.take(config, ["agent", "model"])
    started = DateTime.to_iso8601(DateTime.utc_now())
    pass = %{"id" => id, "observer" => observer, "at" => started, "state" => "observing", "committed" => false}
    anchor = Store.get("bootstrap") || %{"at" => DateTime.utc_now() |> DateTime.shift(week: -1) |> DateTime.to_iso8601()}
    :ok = Store.put_many([{"pass/" <> id, "pass", pass}, {"bootstrap", "bootstrap", anchor}])
    broadcast()
    progress = Map.put_new(Store.get("progress") || %{}, "bootstrap", anchor["at"])
    previous = Store.list("finding", Map.get(progress, "finding_offset", 0), 10)

    with {:ok, batch} <- Evidence.batch(progress),
         {:ok, response} <- ask(batch, previous, config),
         {:ok, documents} <- Publication.prepare(response, batch.sources, previous, id, observer) do
      partial = batch.partial or Enum.count_until(previous, 10) == 10 or Map.get(progress, "finding_offset", 0) > 0

      state = pass_state(batch, partial, documents)

      next =
        Map.merge(batch.next, %{
          "last_success" => started,
          "pending" => batch.pending,
          "finding_offset" =>
            if(Enum.count_until(previous, 10) == 10, do: Map.get(progress, "finding_offset", 0) + 10, else: 0)
        })

      pass =
        Map.merge(pass, %{
          "state" => state,
          "committed" => true,
          "changed_runs" => batch.changed,
          "sources" => batch.sources,
          "partial" => partial,
          "pending" => batch.pending,
          "finding_context_count" => length(previous)
        })

      Store.put_many(documents ++ batch.seen ++ [{"progress", "progress", next}, {"pass/" <> id, "pass", pass}])
    else
      {:error, reason} ->
        :ok =
          Store.put_many([{"pass/" <> id, "pass", Map.merge(pass, %{"state" => "failed", "error" => inspect(reason)})}])

        {:error, reason}
    end
  end

  @spec pass_state(map(), boolean(), [tuple()]) :: String.t()
  defp pass_state(_batch, true, _documents), do: "partial"
  defp pass_state(%{changed: 0}, false, _documents), do: "no_new_evidence"
  defp pass_state(_batch, false, []), do: "no_findings"
  defp pass_state(_batch, false, _documents), do: "successful"

  @spec ask(map(), [map()], map()) :: {:ok, map()} | {:error, term()}
  defp ask(%{changed: 0}, _previous, _settings), do: {:ok, %{"findings" => []}}

  defp ask(batch, previous, settings) do
    witness = Application.get_env(:harness, :insights_witness, Witness)

    witness.observe(
      %{
        "sources" => batch.sources,
        "previous_findings" => Enum.map(previous, &context_finding/1),
        "finding_context" => "Bounded page; prose is limited to 1000 characters per field, citations to two excerpts.",
        "partial_evidence" => batch.partial,
        "history_pending" => batch.pending,
        "scope" => "Bounded evidence page; active observations are provisional."
      },
      settings["model"]
    )
  end

  @spec context_finding(map()) :: map()
  defp context_finding(finding) do
    finding
    |> Map.new(fn {key, value} -> {key, if(is_binary(value), do: String.slice(value, 0, 1000), else: value)} end)
    |> Map.update!("citations", fn citations ->
      citations |> Enum.take(2) |> Enum.map(&Map.update!(&1, "excerpt", fn text -> String.slice(text, 0, 500) end))
    end)
  end

  @spec next_pass(map(), map()) :: String.t() | nil
  defp next_pass(%{"enabled" => false}, _), do: nil

  defp next_pass(_settings, %{"pending" => true}), do: DateTime.to_iso8601(DateTime.utc_now())

  defp next_pass(settings, %{"last_success" => time}) do
    {:ok, date, _} = DateTime.from_iso8601(time)
    date |> DateTime.shift(minute: settings["cadence_minutes"]) |> DateTime.to_iso8601()
  end

  defp next_pass(_, _), do: DateTime.to_iso8601(DateTime.utc_now())

  @spec broadcast() :: :ok
  defp broadcast, do: Phoenix.PubSub.broadcast(Harness.PubSub, @topic, :insights_updated)
end
