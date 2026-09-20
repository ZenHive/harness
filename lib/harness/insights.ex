defmodule Harness.Insights do
  @moduledoc "Independent, disabled-by-default AI observations across runs."
  use Descripex, namespace: "/insights"

  alias Harness.Insights.Attempt
  alias Harness.Insights.Consultation
  alias Harness.Insights.Evidence
  alias Harness.Insights.Publication
  alias Harness.Insights.Selection
  alias Harness.Insights.Store
  alias Harness.Insights.Worker

  @topic "harness:insights"
  @defaults %{"enabled" => false, "cadence_minutes" => 60, "agent" => "codex", "model" => nil}

  api(:status, "Bounded observation settings, last pass and durable progress; independent of dispatch autonomy.",
    returns: %{type: :map, description: "Observer status and persistence mode."}
  )

  @spec status() :: map()
  def status do
    Attempt.reconcile()
    settings = settings()
    progress = Store.get("progress") || %{}
    last = List.first(Store.list("pass", 0, 1))

    %{
      "settings" => settings,
      "selection_error" =>
        case Selection.validate(settings) do
          :ok -> nil
          {:error, reason} -> to_string(reason)
        end,
      "progress" => progress,
      "last_pass" => last,
      "last_success" => progress["last_success"],
      "next_pass" => next_pass(settings, progress),
      "ephemeral" => not Store.persistent?(),
      "state" => if(settings["enabled"], do: (last || %{})["state"] || "ready", else: "disabled")
    }
  end

  @doc false
  @spec settings() :: map()
  def settings, do: Map.merge(Map.merge(@defaults, Selection.default()), Store.get("settings") || %{})

  @doc false
  @spec configure(map()) :: :ok | {:error, term()}
  def configure(%{"enabled" => enabled, "cadence_minutes" => cadence} = settings)
      when is_boolean(enabled) and cadence in [15, 60, 360, 1440] do
    with :ok <- validate_configuration(settings),
         :ok <- Store.put_many([{"settings", "settings", Map.take(settings, Map.keys(@defaults))}]) do
      broadcast()
    end
  end

  def configure(_), do: {:error, :invalid_settings}

  @spec validate_configuration(map()) :: :ok | {:error, term()}
  defp validate_configuration(%{"enabled" => false} = settings) do
    if Map.take(settings, ["agent", "model"]) == Map.take(settings(), ["agent", "model"]),
      do: :ok,
      else: Selection.validate(settings)
  end

  defp validate_configuration(settings), do: Selection.validate(settings)

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

  @doc false
  @spec observe(String.t()) :: :ok | {:error, term()}
  def observe(pass_id) when is_binary(pass_id) do
    result =
      Store.serialized(fn ->
        cond do
          not settings()["enabled"] ->
            {:error, :disabled}

          match?(%{"committed" => true}, Store.get("pass/" <> pass_id)) ->
            :ok

          true ->
            Attempt.reconcile()
            run_pass(pass_id)
        end
      end)

    broadcast()
    result
  end

  @doc false
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Harness.PubSub, @topic)

  @spec run_pass(String.t()) :: :ok | {:error, term()}
  defp run_pass(id) do
    config = settings()
    observer = Map.take(config, ["agent", "model"])
    started = DateTime.to_iso8601(DateTime.utc_now())

    pass = %{
      "id" => id,
      "observer" => observer,
      "at" => started,
      "state" => "observing",
      "committed" => false,
      "owner" => Attempt.owner()
    }

    try do
      execute_pass(pass, config)
    rescue
      error -> fail_pass(pass, {:exception, Exception.message(error)})
    catch
      kind, reason -> fail_pass(pass, {kind, reason})
    end
  end

  @spec execute_pass(map(), map()) :: :ok | {:error, term()}
  defp execute_pass(pass, config) do
    id = pass["id"]
    started = pass["at"]
    observer = pass["observer"]

    anchor = Store.get("bootstrap") || %{"at" => DateTime.utc_now() |> DateTime.shift(week: -1) |> DateTime.to_iso8601()}

    :ok =
      Store.put_many([
        {"pass/" <> id, "pass", pass},
        {"bootstrap", "bootstrap", anchor},
        {"attempt", "attempt", %{"at" => started}}
      ])

    broadcast()
    progress = Map.put_new(Store.get("progress") || %{}, "bootstrap", anchor["at"])

    with :ok <- Selection.validate(config),
         {:ok, batch} <- Evidence.batch(progress),
         {:ok, response, sources, previous} <- Consultation.run(batch, config),
         {:ok, documents} <- Publication.prepare(response, sources, previous, id, observer) do
      state = pass_state(batch, documents)

      next =
        Map.merge(batch.next, %{
          "last_success" => started,
          "pending" => batch.pending
        })

      pass =
        Map.merge(pass, %{
          "state" => state,
          "committed" => true,
          "changed_runs" => batch.changed,
          "sources" => sources,
          "partial" => batch.partial,
          "pending" => batch.pending,
          "finding_context_count" => length(previous)
        })

      case Store.put_many(documents ++ batch.seen ++ [{"progress", "progress", next}, {"pass/" <> id, "pass", pass}]) do
        :ok -> :ok
        {:error, reason} -> fail_pass(pass, {:publication_failed, reason})
      end
    else
      {:error, reason} -> fail_pass(pass, reason)
    end
  end

  @spec fail_pass(map(), term()) :: {:error, term()}
  defp fail_pass(pass, reason) do
    case Attempt.fail(pass, reason) do
      :ok -> {:error, reason}
      {:error, failure} -> {:error, {:failure_publication_failed, reason, failure}}
    end
  end

  @spec pass_state(map(), [tuple()]) :: String.t()
  defp pass_state(%{partial: true}, _documents), do: "partial"
  defp pass_state(%{changed: 0}, _documents), do: "no_new_evidence"
  defp pass_state(_batch, []), do: "no_findings"
  defp pass_state(_batch, _documents), do: "successful"

  @spec next_pass(map(), map()) :: String.t() | nil
  defp next_pass(%{"enabled" => false}, _), do: nil

  defp next_pass(settings, progress) do
    attempt = Store.get("attempt") || %{}
    last = List.first(Store.list("pass", 0, 1)) || %{}
    time = attempt["at"] || progress["last_success"]

    if progress["pending"] == true and last["committed"] == true do
      DateTime.to_iso8601(DateTime.utc_now())
    else
      case time do
        nil ->
          DateTime.to_iso8601(DateTime.utc_now())

        time ->
          {:ok, date, _} = DateTime.from_iso8601(time)
          date |> DateTime.shift(minute: settings["cadence_minutes"]) |> DateTime.to_iso8601()
      end
    end
  end

  @spec broadcast() :: :ok
  defp broadcast, do: Phoenix.PubSub.broadcast(Harness.PubSub, @topic, :insights_updated)
end
