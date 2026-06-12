defmodule Harness.ModelAvailability do
  @moduledoc """
  Per-`{agent, model}` availability — catalog membership and operator/failure blocks.

  Composes with `Harness.AgentRegistry` at dispatch time: a run starts only when
  the adapter is agent-available **and** the resolved model pair is not blocked.
  Blocks persist in `Harness.SettingsStore` (`:model_blocks`); catalogs are probed
  for cursor/grok or operator-maintained static lists for other agents.
  """

  use Descripex, namespace: "/model_availability"

  alias Harness.AgentRegistry
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.SettingsStore

  @blocks_key :model_blocks
  @catalogs_key :model_catalogs
  @static_catalogs_key :model_catalog_static
  @default_catalog_ttl_ms 3_600_000
  @probeable_agents %{cursor: "cursor-agent", grok: "grok", pi: "pi"}
  @catalog_commands %{
    cursor: ["--list-models"],
    grok: ["models"],
    pi: ["--list-models"]
  }

  # UI-only seed catalogs for agents without a probeable `--list-models` surface,
  # so the settings dropdown has options out of the box. Consumed *only* by
  # `selectable_models/1` (the dashboard dropdown) — deliberately NOT by `catalog/1`
  # / the dispatch gate, which stays permissive for these agents (a pinned id absent
  # from this seed must still dispatch). Both id sets are a best-effort seed — edit
  # here when the accepted ids change. A SettingsStore `@static_catalogs_key` entry
  # still overrides at the gate, independent of this UI seed.
  #
  # Ids verified 2026-06-12:
  #   claude — https://support.claude.com/en/articles/11940350-claude-code-model-configuration
  #            https://code.claude.com/docs/en/model-config
  #   codex  — https://developers.openai.com/codex/models
  #            (gpt-5.5 default; gpt-5.2 / gpt-5.3-codex deprecated for ChatGPT sign-in)
  @builtin_ui_catalogs %{
    claude: [
      %{id: "claude-opus-4-8", label: "Opus 4.8", annotations: []},
      %{id: "claude-opus-4-7", label: "Opus 4.7", annotations: []},
      %{id: "claude-fable-5", label: "Fable 5", annotations: []},
      %{id: "claude-sonnet-4-6", label: "Sonnet 4.6", annotations: []},
      %{id: "claude-haiku-4-5-20251001", label: "Haiku 4.5", annotations: []}
    ],
    codex: [
      %{id: "gpt-5.5", label: "GPT-5.5 (recommended)", annotations: []},
      %{id: "gpt-5.4", label: "GPT-5.4", annotations: []},
      %{id: "gpt-5.4-mini", label: "GPT-5.4 mini", annotations: []},
      %{id: "gpt-5.3-codex-spark", label: "GPT-5.3 Codex Spark (Pro)", annotations: []}
    ]
  }

  @type block_source :: :operator | :failure
  @type block_entry :: %{
          until: DateTime.t() | nil,
          reason: String.t(),
          source: block_source()
        }
  @type blocks :: %{{atom(), String.t() | :all} => block_entry()}
  @type catalog_entry :: %{id: String.t(), label: String.t(), annotations: [String.t()]}

  @doc false
  @spec blocks_key() :: atom()
  def blocks_key, do: @blocks_key

  # Internal query (consumed by Dispatch/Run): catalog-listed AND not blocked-now.
  @doc false
  @spec available?(atom(), String.t() | nil) :: boolean()
  def available?(agent, model) when is_atom(agent) do
    not blocked_now?(agent, model) and catalog_allows?(agent, model)
  end

  # Internal query (consumed by Dispatch/Run): active block expiry, or nil.
  @doc false
  @spec blocked_until(atom(), String.t() | :all) :: DateTime.t() | nil
  def blocked_until(agent, model) when is_atom(agent) and (is_binary(model) or model == :all) do
    case active_block(agent, model) do
      %{until: until} -> until
      nil -> nil
    end
  end

  # Internal query (consumed by Dispatch/Run): catalog entries not currently blocked.
  @doc false
  @spec list_available(atom()) :: [map()] | {:error, :catalog_unavailable}
  def list_available(agent) when is_atom(agent) do
    with {:ok, catalog} <- catalog(agent), do: available_catalog_entries(agent, catalog)
  end

  @spec available_catalog_entries(atom(), [catalog_entry()]) :: [map()]
  defp available_catalog_entries(agent, catalog) do
    if blocked_now?(agent, :all), do: [], else: Enum.flat_map(catalog, &available_catalog_entry(agent, &1))
  end

  @spec available_catalog_entry(atom(), catalog_entry()) :: [map()]
  defp available_catalog_entry(agent, %{id: id} = entry) do
    if blocked_now?(agent, id), do: [], else: [entry_map(entry, nil)]
  end

  # UI query (consumed by the settings dropdown): the agent's available catalog,
  # falling back to the built-in seed when the agent has no probeable/static
  # catalog. Distinct from `list_available/1` on purpose — this overlays
  # `@builtin_ui_catalogs` so claude/codex get a dropdown, WITHOUT feeding the
  # dispatch gate (which keeps treating them as catalog-free → permissive).
  # Blocked-now ids are still dropped. Empty list ⇒ no options (render a text input).
  @doc false
  @spec selectable_models(atom()) :: [map()]
  def selectable_models(agent) when is_atom(agent) do
    case list_available(agent) do
      entries when is_list(entries) and entries != [] -> entries
      _ -> builtin_selectable(agent)
    end
  end

  @spec builtin_selectable(atom()) :: [map()]
  defp builtin_selectable(agent) do
    @builtin_ui_catalogs
    |> Map.get(agent, [])
    |> Enum.flat_map(fn %{id: id} = entry ->
      if blocked_now?(agent, id), do: [], else: [entry_map(entry, nil)]
    end)
  end

  # Internal query (consumed by Dispatch/Run): available model ids for error tuples.
  @doc false
  @spec list_available_ids(atom()) :: [String.t()]
  def list_available_ids(agent) when is_atom(agent) do
    case list_available(agent) do
      {:error, :catalog_unavailable} -> []
      entries when is_list(entries) -> Enum.map(entries, & &1.id)
    end
  end

  @doc false
  @spec record_block(atom(), String.t() | :all, keyword()) :: :ok
  def record_block(agent, model, opts \\ []) when is_atom(agent) do
    until = Keyword.get(opts, :until)
    reason = Keyword.get(opts, :reason, "")
    source = Keyword.get(opts, :source, :operator)

    entry = %{
      until: until,
      reason: reason,
      source: source
    }

    blocks = Map.put(blocks(), pair_key(agent, model), entry)
    persist_blocks(blocks)
    :ok
  end

  @doc false
  @spec clear_block(atom(), String.t() | :all) :: :ok
  def clear_block(agent, model) when is_atom(agent) do
    blocks = Map.delete(blocks(), pair_key(agent, model))
    persist_blocks(blocks)
    :ok
  end

  @doc false
  @spec capture_structured_failure(module(), term(), keyword()) :: :ok
  def capture_structured_failure(adapter, reason, opts \\ []) when is_atom(adapter) do
    with {:ok, agent} <- AgentRegistry.agent_for_module(adapter),
         {:ok, seconds, model} <- structured_quota_signal(reason) do
      model = model || Keyword.get(opts, :model)
      until = DateTime.add(DateTime.utc_now(), seconds, :second)

      record_block(agent, model || :all,
        until: until,
        reason: "structured quota signal",
        source: :failure
      )
    else
      _ -> :ok
    end
  end

  @doc false
  @spec structured_quota_signal(term()) :: {:ok, pos_integer(), String.t() | nil} | :error
  def structured_quota_signal(reason), do: do_structured_quota_signal(reason)

  # Test/diagnostic entry point: parse a raw CLI catalog dump for an agent into
  # deduped entries, exercising the per-agent line parser without shelling out.
  @doc false
  @spec parse_catalog_output(atom(), String.t()) :: [catalog_entry()]
  def parse_catalog_output(agent, output) when is_atom(agent) and is_binary(output) do
    catalog_lines_to_entries(agent, output)
  end

  @doc false
  @spec parse_catalog_line(String.t()) :: catalog_entry() | :error
  def parse_catalog_line(line) when is_binary(line) do
    line = String.trim(line)

    cond do
      line == "" -> :error
      String.starts_with?(line, "#") -> :error
      true -> parse_id_label_line(line)
    end
  end

  @doc false
  @spec notify_blocked_dispatch(atom(), String.t() | nil, String.t() | nil) :: :ok
  def notify_blocked_dispatch(agent, model, task_id \\ nil) when is_atom(agent) do
    Notification.notify(%Event{
      type: :model_unavailable,
      task_id: task_id || "dispatch",
      outcome: %{agent: Atom.to_string(agent), model: model, available: list_available_ids(agent)}
    })
  end

  api(
    :list_available_models,
    "List models for an agent from its catalog minus active blocks.",
    params: [
      agent: [kind: :value, description: ~s{Agent name string (e.g. "cursor", "codex").}],
      opts: [kind: :value, default: [], description: "Reserved keyword list (currently unused)."]
    ],
    returns: %{
      type: :tuple,
      description: "{:ok, %{models: [%{id, label, blocked_until}]}} or {:ok, %{catalog_unavailable: true, models: []}}."
    }
  )

  @spec list_available_models(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_available_models(agent, opts \\ []) when is_binary(agent) and is_list(opts) do
    with {:ok, agent_atom} <- coerce_agent(agent) do
      case list_available(agent_atom) do
        {:error, :catalog_unavailable} ->
          {:ok, %{catalog_unavailable: true, models: []}}

        models ->
          {:ok, %{catalog_unavailable: false, models: models}}
      end
    end
  end

  api(
    :block_model,
    "Operator-declare a block on an {agent, model} pair (model \"all\" blocks the whole agent).",
    params: [
      agent: [kind: :value, description: "Agent name string."],
      model: [kind: :value, description: "Model id string, or \"all\" for agent-wide block."],
      opts: [
        kind: :value,
        default: [],
        description: "Keyword list with :until ISO8601 string and :reason string."
      ]
    ],
    returns: %{type: :atom, description: ":ok on success."}
  )

  @spec block_model(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def block_model(agent, model, opts \\ []) when is_binary(agent) and is_binary(model) and is_list(opts) do
    with {:ok, agent_atom} <- coerce_agent(agent),
         {:ok, model_key} <- coerce_model_key(model),
         {:ok, until} <- parse_until(Keyword.get(opts, :until)) do
      reason = Keyword.get(opts, :reason, "")
      record_block(agent_atom, model_key, until: until, reason: reason, source: :operator)
      :ok
    end
  end

  api(
    :unblock_model,
    "Clear an operator or failure-captured block on an {agent, model} pair.",
    params: [
      agent: [kind: :value, description: "Agent name string."],
      model: [kind: :value, description: "Model id string, or \"all\"."]
    ],
    returns: %{type: :atom, description: ":ok on success."}
  )

  @spec unblock_model(String.t(), String.t()) :: :ok | {:error, term()}
  def unblock_model(agent, model) when is_binary(agent) and is_binary(model) do
    with {:ok, agent_atom} <- coerce_agent(agent),
         {:ok, model_key} <- coerce_model_key(model) do
      clear_block(agent_atom, model_key)
      :ok
    end
  end

  api(:list_blocks, "List all persisted model blocks across agents.",
    returns: %{
      type: :tuple,
      description: "{:ok, %{blocks: [%{agent, model, until, reason, source}]}} — until is ISO8601 or null."
    }
  )

  @spec list_blocks() :: {:ok, %{blocks: [map()]}}
  def list_blocks do
    blocks =
      blocks()
      |> Enum.filter(fn {{agent, model}, _entry} -> active_block(agent, model) != nil end)
      |> Enum.map(fn {{agent, model}, entry} ->
        %{
          agent: Atom.to_string(agent),
          model: model_key_to_string(model),
          until: format_until(entry.until),
          reason: entry.reason,
          source: Atom.to_string(entry.source)
        }
      end)

    {:ok, %{blocks: blocks}}
  end

  api(
    :refresh_catalog,
    "Re-probe an agent CLI catalog (cursor/grok) or return the operator static list.",
    params: [agent: [kind: :value, description: "Agent name string."]],
    returns: %{
      type: :tuple,
      description: "{:ok, %{models: [%{id, label}]}} or {:error, :catalog_unavailable}."
    }
  )

  @spec refresh_catalog(String.t()) :: {:ok, map()} | {:error, term()}
  def refresh_catalog(agent) when is_binary(agent) do
    with {:ok, agent_atom} <- coerce_agent(agent),
         {:ok, catalog} <- refresh_catalog_for(agent_atom) do
      {:ok, %{models: Enum.map(catalog, &Map.take(&1, [:id, :label]))}}
    end
  end

  @spec pair_key(atom(), String.t() | :all) :: {atom(), String.t() | :all}
  defp pair_key(agent, model), do: {agent, model}

  @spec blocks() :: blocks()
  defp blocks do
    case SettingsStore.fetch(@blocks_key) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @spec persist_blocks(blocks()) :: :ok
  defp persist_blocks(blocks), do: SettingsStore.put(@blocks_key, blocks)

  @spec blocked_now?(atom(), String.t() | nil | :all) :: boolean()
  defp blocked_now?(agent, model) do
    agent_blocked?(agent) or (is_binary(model) and pair_blocked?(agent, model))
  end

  @spec agent_blocked?(atom()) :: boolean()
  defp agent_blocked?(agent), do: active_block(agent, :all) != nil

  @spec pair_blocked?(atom(), String.t()) :: boolean()
  defp pair_blocked?(agent, model), do: active_block(agent, model) != nil

  @spec active_block(atom(), String.t() | :all) :: block_entry() | nil
  defp active_block(agent, model) do
    case Map.get(blocks(), pair_key(agent, model)) do
      %{until: until} = entry when is_struct(until, DateTime) ->
        if DateTime.after?(until, DateTime.utc_now()), do: entry

      %{until: nil} = entry ->
        entry

      _ ->
        nil
    end
  end

  @spec catalog_allows?(atom(), String.t() | nil) :: boolean()
  defp catalog_allows?(_agent, nil), do: true

  defp catalog_allows?(agent, model) do
    case catalog(agent) do
      {:ok, entries} -> Enum.any?(entries, &(&1.id == model))
      {:error, :catalog_unavailable} -> true
    end
  end

  @spec catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp catalog(agent) do
    if Map.has_key?(@probeable_agents, agent) do
      cached_or_probe(agent)
    else
      static_catalog(agent)
    end
  end

  @spec cached_or_probe(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp cached_or_probe(agent) do
    case cached_catalog(agent) do
      {:ok, catalog, true} -> {:ok, catalog}
      _ -> probe_and_cache(agent)
    end
  end

  @spec cached_catalog(atom()) :: {:ok, [catalog_entry()], boolean()} | :miss
  defp cached_catalog(agent) do
    case SettingsStore.fetch(@catalogs_key) do
      {:ok, %{^agent => %{fetched_at: fetched_at, models: models}}} when is_list(models) ->
        fresh? = fresh_catalog?(fetched_at)
        {:ok, models, fresh?}

      _ ->
        :miss
    end
  end

  @spec fresh_catalog?(DateTime.t()) :: boolean()
  defp fresh_catalog?(fetched_at) do
    ttl = Application.get_env(:harness, :model_catalog_ttl_ms, @default_catalog_ttl_ms)
    DateTime.diff(DateTime.utc_now(), fetched_at, :millisecond) < ttl
  end

  @spec probe_and_cache(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp probe_and_cache(agent) do
    case probe_catalog(agent) do
      {:ok, models} ->
        store_catalog(agent, models)
        {:ok, models}

      {:error, :catalog_unavailable} = error ->
        error
    end
  end

  @spec refresh_catalog_for(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp refresh_catalog_for(agent) do
    if Map.has_key?(@probeable_agents, agent) do
      probe_and_cache(agent)
    else
      static_catalog(agent)
    end
  end

  @spec store_catalog(atom(), [catalog_entry()]) :: :ok
  defp store_catalog(agent, models) do
    catalogs =
      case SettingsStore.fetch(@catalogs_key) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    entry = %{fetched_at: DateTime.utc_now(), models: models}
    SettingsStore.put(@catalogs_key, Map.put(catalogs, agent, entry))
  end

  @spec static_catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp static_catalog(agent) do
    case SettingsStore.fetch(@static_catalogs_key) do
      {:ok, %{^agent => models}} when is_list(models) and models != [] -> {:ok, models}
      _ -> {:error, :catalog_unavailable}
    end
  end

  @spec probe_catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp probe_catalog(agent) do
    probe_fn = Application.get_env(:harness, :model_catalog_probe, &default_probe/2)
    probe_fn.(agent, @probeable_agents)
  end

  @spec default_probe(atom(), map()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp default_probe(agent, executables) do
    with {:ok, executable} <- Map.fetch(executables, agent),
         {:ok, args} <- Map.fetch(@catalog_commands, agent),
         path when is_binary(path) <- System.find_executable(executable),
         {output, 0} <- System.cmd(path, args, stderr_to_stdout: true) do
      models = catalog_lines_to_entries(agent, output)

      if models == [], do: {:error, :catalog_unavailable}, else: {:ok, models}
    else
      # A missing/unauthed CLI exits non-zero — degrade to unavailable, never raise
      # (the settings page probes on every mount; a MatchError here would 500 it).
      _ -> {:error, :catalog_unavailable}
    end
  end

  # Each probeable CLI prints its model list in its own shape, so parsing dispatches
  # on agent. Entries are deduped by id (pi can list the same id under >1 provider).
  @spec catalog_lines_to_entries(atom(), String.t()) :: [catalog_entry()]
  defp catalog_lines_to_entries(agent, output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&catalog_line_entry(agent, &1))
    |> Enum.uniq_by(& &1.id)
  end

  @spec catalog_line_entry(atom(), String.t()) :: [catalog_entry()]
  defp catalog_line_entry(agent, line) do
    case parse_agent_line(agent, line) do
      :error -> []
      entry -> [entry]
    end
  end

  # cursor: "id (ann) - Label" — the original `parse_catalog_line/1` shape.
  # grok:   bullet rows "  * id (default)" / "  - id" with no label column.
  # pi:     a whitespace-column table "provider  model  context …" (skip header).
  @spec parse_agent_line(atom(), String.t()) :: catalog_entry() | :error
  defp parse_agent_line(:grok, line), do: parse_grok_line(line)
  defp parse_agent_line(:pi, line), do: parse_pi_line(line)
  defp parse_agent_line(_cursor, line), do: parse_catalog_line(line)

  @spec parse_grok_line(String.t()) :: catalog_entry() | :error
  defp parse_grok_line(line) do
    case Regex.run(~r/^\s*[*-]\s+(\S+)(.*)$/, line) do
      [_full, id, rest] ->
        {_stripped, annotations} = strip_annotations(rest)
        %{id: id, label: id, annotations: annotations}

      _no_bullet ->
        :error
    end
  end

  @spec parse_pi_line(String.t()) :: catalog_entry() | :error
  defp parse_pi_line(line) do
    case String.split(line, ~r/\s{2,}/, trim: true) do
      ["provider", "model" | _header] -> :error
      [provider, model | _rest] when model != "" -> %{id: model, label: provider, annotations: []}
      _other -> :error
    end
  end

  @spec parse_id_label_line(String.t()) :: catalog_entry() | :error
  defp parse_id_label_line(line) do
    case String.split(line, " - ", parts: 2) do
      [id_part, label_part] ->
        {id, annotations} = strip_annotations(id_part)

        if id == "" do
          :error
        else
          label = label_part |> strip_annotations() |> elem(0) |> String.trim()
          %{id: id, label: label, annotations: annotations}
        end

      _ ->
        :error
    end
  end

  @spec strip_annotations(String.t()) :: {String.t(), [String.t()]}
  defp strip_annotations(text) do
    ~r/\(([^)]+)\)/
    |> Regex.scan(text)
    |> Enum.map(fn [_full, inner] -> inner end)
    |> then(fn annotations ->
      stripped = String.trim(Regex.replace(~r/\s*\([^)]+\)/, text, ""))
      {stripped, annotations}
    end)
  end

  @spec entry_map(catalog_entry(), DateTime.t() | nil) :: map()
  defp entry_map(%{id: id, label: label}, blocked_until) do
    %{id: id, label: label, blocked_until: format_until(blocked_until)}
  end

  @spec format_until(DateTime.t() | nil) :: String.t() | nil
  defp format_until(nil), do: nil
  defp format_until(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  @spec coerce_agent(String.t()) :: {:ok, atom()} | {:error, term()}
  defp coerce_agent(agent) do
    if agent in Enum.map(AgentRegistry.agents(), fn {a, _} -> Atom.to_string(a) end) do
      {:ok, String.to_existing_atom(agent)}
    else
      {:error, {:invalid_agent, agent}}
    end
  end

  @spec coerce_model_key(String.t()) :: {:ok, String.t() | :all} | {:error, term()}
  defp coerce_model_key("all"), do: {:ok, :all}
  defp coerce_model_key(model) when is_binary(model), do: {:ok, model}

  @spec model_key_to_string(String.t() | :all) :: String.t()
  defp model_key_to_string(:all), do: "all"
  defp model_key_to_string(model) when is_binary(model), do: model

  @spec parse_until(nil) :: {:ok, nil}
  defp parse_until(nil), do: {:ok, nil}

  @spec parse_until(String.t()) :: {:ok, DateTime.t()} | {:error, term()}
  defp parse_until(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, reason} -> {:error, {:invalid_until, reason}}
    end
  end

  @spec do_structured_quota_signal(term()) :: {:ok, pos_integer(), String.t() | nil} | :error
  defp do_structured_quota_signal({:agent_spawn_failed, inner}), do: do_structured_quota_signal(inner)
  defp do_structured_quota_signal({:structured_quota, payload}) when is_map(payload), do: quota_from_map(payload)

  defp do_structured_quota_signal(payload) when is_map(payload) do
    quota_from_map(normalize_map_keys(payload))
  end

  defp do_structured_quota_signal(_), do: :error

  @spec quota_from_map(map()) :: {:ok, pos_integer(), String.t() | nil} | :error
  defp quota_from_map(%{"status" => 429} = map), do: atomize_429_map(map)
  defp quota_from_map(%{status: 429} = map), do: extract_retry_after(map)

  defp quota_from_map(_), do: :error

  @spec atomize_429_map(map()) :: {:ok, pos_integer(), String.t() | nil} | :error
  defp atomize_429_map(map) do
    map
    |> Map.new(fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      pair -> pair
    end)
    |> extract_retry_after()
  rescue
    ArgumentError -> :error
  end

  @spec extract_retry_after(map()) :: {:ok, pos_integer(), String.t() | nil} | :error
  defp extract_retry_after(map) do
    case retry_after_seconds(map) do
      seconds when is_integer(seconds) and seconds > 0 ->
        model = model_from_map(map)
        {:ok, seconds, model}

      _ ->
        :error
    end
  end

  @spec retry_after_seconds(map()) :: non_neg_integer() | nil
  defp retry_after_seconds(map) do
    Map.get(map, :retry_after_seconds) || Map.get(map, :retry_after) || Map.get(map, "retry_after")
  end

  @spec model_from_map(map()) :: String.t() | nil
  defp model_from_map(map) do
    case Map.get(map, :model) || Map.get(map, "model") do
      model when is_binary(model) and model != "" -> model
      _ -> nil
    end
  end

  @spec normalize_map_keys(map()) :: map()
  defp normalize_map_keys(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      pair -> pair
    end)
  end
end
