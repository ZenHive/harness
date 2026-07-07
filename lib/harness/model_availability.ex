defmodule Harness.ModelAvailability do
  @moduledoc """
  Per-`{agent, model}` availability — advisory model catalogs and operator/failure blocks.

  Composes with `Harness.AgentRegistry` at dispatch time: a run starts only when
  the adapter is agent-available **and** the resolved model pair is not blocked.
  Blocks persist in `Harness.SettingsStore` (`:model_blocks`); catalogs keep the
  operator-selected subset separate from cached live probes and manual ids.
  """

  use Descripex, namespace: "/model_availability"

  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentRegistry
  alias Harness.ModelAvailability.CatalogEntry
  alias Harness.Notification
  alias Harness.Notification.Event
  alias Harness.SettingsStore

  @blocks_key :model_blocks
  @catalogs_key :model_catalogs
  @static_catalogs_key :model_catalog_static
  @manual_catalogs_key :model_catalog_manual
  @default_catalog_ttl_ms 3_600_000
  @probeable_agents %{cursor: "cursor-agent", grok: "grok", pi: "pi", codex: "codex", antigravity: "agy"}

  # claude has no model-list CLI (`claude model list` is treated as a prompt —
  # anthropics/claude-code#12612), so its dropdown options come only from this seed.
  # codex IS probeable (`codex debug models` → JSON) and goes through
  # `@probeable_agents`; its seed here is the fallback for when the probe fails
  # (codex CLI absent/unauthed), so operators have options out of the box.
  #
  # Ids verified 2026-06-12:
  #   claude — https://support.claude.com/en/articles/11940350-claude-code-model-configuration
  #            https://code.claude.com/docs/en/model-config
  #   codex  — https://developers.openai.com/codex/models
  @builtin_catalogs %{
    claude: [
      CatalogEntry.new("claude-opus-4-8", "Opus 4.8"),
      CatalogEntry.new("claude-opus-4-7", "Opus 4.7"),
      CatalogEntry.new("claude-fable-5", "Fable 5"),
      CatalogEntry.new("claude-sonnet-5", "Sonnet 5"),
      CatalogEntry.new("claude-sonnet-4-6", "Sonnet 4.6"),
      CatalogEntry.new("claude-haiku-4-5-20251001", "Haiku 4.5")
    ],
    codex: [
      CatalogEntry.new("gpt-5.5", "GPT-5.5 (recommended)"),
      CatalogEntry.new("gpt-5.4", "GPT-5.4"),
      CatalogEntry.new("gpt-5.4-mini", "GPT-5.4 mini"),
      CatalogEntry.new("gpt-5.3-codex-spark", "GPT-5.3 Codex Spark (Pro)")
    ]
  }

  @type block_source :: :operator | :failure
  @type block_entry :: %{
          until: DateTime.t() | nil,
          reason: String.t(),
          source: block_source()
        }
  @type blocks :: %{{atom(), String.t() | :all} => block_entry()}
  @type catalog_entry :: CatalogEntry.t()

  @doc false
  @spec blocks_key() :: atom()
  def blocks_key, do: @blocks_key

  @doc false
  @spec static_catalogs_key() :: atom()
  def static_catalogs_key, do: @static_catalogs_key

  @doc false
  @spec probeable?(atom()) :: boolean()
  def probeable?(agent) when is_atom(agent), do: Map.has_key?(@probeable_agents, agent)

  # Internal query (consumed by Dispatch/Run): catalog membership is advisory;
  # only active operator/failure blocks hard-gate dispatch.
  @doc false
  @spec available?(atom(), String.t() | nil) :: boolean()
  def available?(agent, model) when is_atom(agent) do
    not blocked_now?(agent, model)
  end

  # Internal query (consumed by Dispatch/Run): active block expiry, or nil.
  @doc false
  @spec blocked_until(atom(), :all) :: DateTime.t() | nil
  def blocked_until(agent, :all) when is_atom(agent), do: do_blocked_until(agent, :all)

  @doc false
  @spec blocked_until(atom(), String.t()) :: DateTime.t() | nil
  def blocked_until(agent, model) when is_atom(agent) and is_binary(model), do: do_blocked_until(agent, model)

  @spec do_blocked_until(atom(), String.t() | :all) :: DateTime.t() | nil
  defp do_blocked_until(agent, model) do
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
  # deduped entries, exercising the per-agent parser without shelling out. codex
  # emits JSON, every other probeable CLI emits lines — so dispatch on agent.
  @doc false
  @spec parse_catalog_output(atom(), String.t()) :: [catalog_entry()]
  def parse_catalog_output(:codex, output) when is_binary(output), do: parse_codex_json(output)

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
      description:
        "{:ok, %{catalog_status: \"available\", catalog_unavailable: false, models: [%{id, label, blocked_until}]}} " <>
          "when the operator-selected subset has dispatchable entries; " <>
          "{:ok, %{catalog_status: \"probed_none_selected\", catalog_unavailable: true, models: [], universe_count: N}} " <>
          "when catalog_universe/1 is non-empty but nothing is selected; " <>
          "{:ok, %{catalog_status: \"unavailable\", catalog_unavailable: true, models: []}} " <>
          "when no universe exists (probe failed / nothing declared / no builtin)."
    }
  )

  @spec list_available_models(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_available_models(agent, opts \\ []) when is_binary(agent) and is_list(opts) do
    with {:ok, agent_atom} <- coerce_agent(agent) do
      case list_available(agent_atom) do
        {:error, :catalog_unavailable} ->
          list_available_models_unavailable(agent_atom)

        models ->
          {:ok, %{catalog_status: "available", catalog_unavailable: false, models: models}}
      end
    end
  end

  @spec list_available_models_unavailable(atom()) :: {:ok, map()}
  defp list_available_models_unavailable(agent) do
    case catalog_universe(agent) do
      {:ok, universe} ->
        {:ok,
         %{
           catalog_status: "probed_none_selected",
           catalog_unavailable: true,
           models: [],
           universe_count: length(universe)
         }}

      {:error, :catalog_unavailable} ->
        {:ok, %{catalog_status: "unavailable", catalog_unavailable: true, models: []}}
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
    "Re-probe an agent CLI catalog and cache it as the model universe.",
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

  @doc false
  @spec add_catalog_model(String.t(), String.t()) :: :ok | {:error, term()}
  def add_catalog_model(agent, model) when is_binary(agent) and is_binary(model) do
    with {:ok, agent_atom} <- coerce_agent(agent),
         {:ok, model_id} <- normalize_model_id(model) do
      model = CatalogEntry.new(model_id, model_id)

      :ok = persist_manual_catalog(agent_atom, merge_catalogs(manual_catalog(agent_atom), [model]))
      persist_static_catalog(agent_atom, merge_catalogs(selected_seed(agent_atom), [model]))
    end
  end

  @doc false
  @spec remove_catalog_model(String.t(), String.t()) :: :ok | {:error, term()}
  def remove_catalog_model(agent, model) when is_binary(agent) and is_binary(model) do
    with {:ok, agent_atom} <- coerce_agent(agent),
         {:ok, model_id} <- normalize_model_id(model) do
      persist_static_catalog(agent_atom, deselect_model(agent_atom, model_id))
    end
  end

  @doc false
  @spec toggle_catalog_model(String.t(), String.t()) :: :ok | {:error, term()}
  def toggle_catalog_model(agent, model) when is_binary(agent) and is_binary(model) do
    with {:ok, agent_atom} <- coerce_agent(agent),
         {:ok, model_id} <- normalize_model_id(model) do
      toggle_selected_model(agent_atom, model_id)
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

  @doc false
  @spec catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  def catalog(agent) when is_atom(agent) do
    with {:error, :catalog_unavailable} <- static_catalog(agent) do
      builtin_catalog(agent)
    end
  end

  @doc false
  @spec catalog_universe(atom()) :: {:ok, [map()]} | {:error, :catalog_unavailable}
  def catalog_universe(agent) when is_atom(agent) do
    selected = selected_seed(agent)
    selected_ids = MapSet.new(selected, & &1.id)

    universe =
      selected
      |> merge_catalogs(probed_seed(agent))
      |> merge_catalogs(manual_catalog(agent))
      |> Enum.map(&Map.put(&1, :selected?, MapSet.member?(selected_ids, &1.id)))

    case universe do
      [] -> {:error, :catalog_unavailable}
      models -> {:ok, models}
    end
  end

  @spec probed_catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp probed_catalog(agent) do
    if probeable?(agent), do: cached_or_probe(agent), else: {:error, :catalog_unavailable}
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
    with true <- probeable?(agent),
         {:ok, _probed} <- probe_and_cache(agent) do
      catalog(agent)
    else
      false -> catalog(agent)
      {:error, :catalog_unavailable} = error -> error
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
      {:ok, %{^agent => models}} when is_list(models) -> {:ok, models}
      _ -> {:error, :catalog_unavailable}
    end
  end

  @spec manual_catalog(atom()) :: [catalog_entry()]
  defp manual_catalog(agent) do
    case SettingsStore.fetch(@manual_catalogs_key) do
      {:ok, %{^agent => models}} when is_list(models) -> models
      _ -> []
    end
  end

  @spec builtin_catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp builtin_catalog(agent) do
    case Map.get(@builtin_catalogs, agent, []) do
      [] -> {:error, :catalog_unavailable}
      models -> {:ok, models}
    end
  end

  @spec selected_seed(atom()) :: [catalog_entry()]
  defp selected_seed(agent) do
    case static_catalog(agent) do
      {:ok, models} -> models
      {:error, :catalog_unavailable} -> builtin_seed(agent)
    end
  end

  @spec builtin_seed(atom()) :: [catalog_entry()]
  defp builtin_seed(agent) do
    case builtin_catalog(agent) do
      {:ok, models} -> models
      {:error, :catalog_unavailable} -> []
    end
  end

  @spec probed_seed(atom()) :: [catalog_entry()]
  defp probed_seed(agent) do
    case probed_catalog(agent) do
      {:ok, models} -> models
      {:error, :catalog_unavailable} -> []
    end
  end

  @spec merge_catalogs([catalog_entry()], [catalog_entry()]) :: [catalog_entry()]
  defp merge_catalogs(existing, incoming), do: Enum.uniq_by(existing ++ incoming, & &1.id)

  @spec persist_static_catalog(atom(), [catalog_entry()]) :: :ok
  defp persist_static_catalog(agent, models) do
    catalogs =
      case SettingsStore.fetch(@static_catalogs_key) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    SettingsStore.put(@static_catalogs_key, Map.put(catalogs, agent, models))
  end

  @spec persist_manual_catalog(atom(), [catalog_entry()]) :: :ok
  defp persist_manual_catalog(agent, models) do
    catalogs =
      case SettingsStore.fetch(@manual_catalogs_key) do
        {:ok, map} when is_map(map) -> map
        _ -> %{}
      end

    SettingsStore.put(@manual_catalogs_key, Map.put(catalogs, agent, models))
  end

  @spec toggle_selected_model(atom(), String.t()) :: :ok
  defp toggle_selected_model(agent, model_id) do
    if selected_model?(agent, model_id) do
      persist_static_catalog(agent, deselect_model(agent, model_id))
    else
      select_model(agent, model_id)
    end
  end

  @spec selected_model?(atom(), String.t()) :: boolean()
  defp selected_model?(agent, model_id), do: Enum.any?(selected_seed(agent), &(&1.id == model_id))

  @spec deselect_model(atom(), String.t()) :: [catalog_entry()]
  defp deselect_model(agent, model_id), do: Enum.reject(selected_seed(agent), &(&1.id == model_id))

  @spec select_model(atom(), String.t()) :: :ok
  defp select_model(agent, model_id) do
    found = universe_model(agent, model_id)
    model = found || CatalogEntry.new(model_id, model_id)

    if found == nil do
      :ok = persist_manual_catalog(agent, merge_catalogs(manual_catalog(agent), [model]))
    end

    persist_static_catalog(agent, merge_catalogs(selected_seed(agent), [model]))
  end

  @spec universe_model(atom(), String.t()) :: catalog_entry() | nil
  defp universe_model(agent, model_id) do
    agent
    |> universe_seed()
    |> Enum.find(&(&1.id == model_id))
  end

  @spec universe_seed(atom()) :: [catalog_entry()]
  defp universe_seed(agent),
    do: agent |> selected_seed() |> merge_catalogs(probed_seed(agent)) |> merge_catalogs(manual_catalog(agent))

  @spec probe_catalog(atom()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp probe_catalog(agent) do
    probe_fn = Application.get_env(:harness, :model_catalog_probe, &default_probe/2)
    probe_fn.(agent, @probeable_agents)
  end

  @spec default_probe(atom(), map()) :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp default_probe(:cursor, _executables), do: run_cursor_probe()
  defp default_probe(:grok, _executables), do: run_grok_probe()
  defp default_probe(:pi, _executables), do: run_pi_probe()
  defp default_probe(:codex, _executables), do: run_codex_probe()
  defp default_probe(:antigravity, _executables), do: run_antigravity_probe()
  defp default_probe(_agent, _executables), do: {:error, :catalog_unavailable}

  @spec run_cursor_probe() :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp run_cursor_probe do
    probe_command(:cursor, fn -> System.cmd("cursor-agent", ["--list-models"], stderr_to_stdout: true) end)
  end

  @spec run_grok_probe() :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp run_grok_probe, do: probe_command(:grok, fn -> System.cmd("grok", ["models"], stderr_to_stdout: true) end)

  @spec run_pi_probe() :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp run_pi_probe, do: probe_command(:pi, fn -> System.cmd("pi", ["--list-models"], stderr_to_stdout: true) end)

  @spec run_codex_probe() :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp run_codex_probe do
    probe_command(:codex, fn -> System.cmd("codex", ["debug", "models"], stderr_to_stdout: true) end)
  end

  @spec run_antigravity_probe() :: {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp run_antigravity_probe do
    # `agy models` prints its list and the foreground process exits, but `agy`
    # leaves a background process attached to the inherited stdin, so a plain
    # `System.cmd("agy", ["models"])` never sees EOF on the port and blocks the
    # BEAM until the caller's timeout. Running through a shell with stdin from
    # `/dev/null` detaches that process and the probe returns promptly. A missing
    # `agy` makes the shell exit 127, which `parse_probe_result/2` maps to
    # `:catalog_unavailable` like the other probes.
    probe_command(:antigravity, fn -> System.cmd("sh", ["-c", "agy models </dev/null 2>&1"]) end)
  end

  @spec probe_command(atom(), (-> {String.t(), non_neg_integer()})) ::
          {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp probe_command(agent, command) do
    parse_probe_result(command.(), agent)
  rescue
    # A missing CLI raises — degrade to unavailable, never crash the settings page.
    ErlangError -> {:error, :catalog_unavailable}
  end

  @spec parse_probe_result({String.t(), non_neg_integer()}, atom()) ::
          {:ok, [catalog_entry()]} | {:error, :catalog_unavailable}
  defp parse_probe_result({output, 0}, agent) do
    models = parse_catalog_output(agent, output)
    if models == [], do: {:error, :catalog_unavailable}, else: {:ok, models}
  end

  defp parse_probe_result({_output, _status}, _agent), do: {:error, :catalog_unavailable}

  # `codex debug models` JSON: keep `visibility: "list"` slugs (drops internal "hide"
  # entries like codex-auto-review); label from display_name, id from slug.
  @spec parse_codex_json(String.t()) :: [catalog_entry()]
  defp parse_codex_json(output) do
    case Jason.decode(output) do
      {:ok, %{"models" => models}} when is_list(models) ->
        models |> Enum.flat_map(&codex_model_entry/1) |> Enum.uniq_by(& &1.id)

      _not_decodable ->
        []
    end
  end

  @spec codex_model_entry(map()) :: [catalog_entry()]
  defp codex_model_entry(%{"slug" => slug, "visibility" => "list"} = model) when is_binary(slug) do
    [CatalogEntry.new(slug, Map.get(model, "display_name", slug))]
  end

  defp codex_model_entry(_hidden_or_malformed), do: []

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
  defp parse_agent_line(:antigravity, line), do: parse_antigravity_line(line)
  defp parse_agent_line(_cursor, line), do: parse_catalog_line(line)

  @spec parse_grok_line(String.t()) :: catalog_entry() | :error
  defp parse_grok_line(line) do
    case Regex.run(~r/^\s*[*-]\s+(\S+)(.*)$/, line) do
      [_full, id, rest] ->
        {_stripped, annotations} = strip_annotations(rest)
        CatalogEntry.new(id, id, annotations)

      _no_bullet ->
        :error
    end
  end

  @spec parse_pi_line(String.t()) :: catalog_entry() | :error
  defp parse_pi_line(line) do
    case String.split(line, ~r/\s{2,}/, trim: true) do
      ["provider", "model" | _header] -> :error
      [provider, model | _rest] when model != "" -> CatalogEntry.new(model, provider)
      _other -> :error
    end
  end

  # agy models prints display labels; map each to its dash-form id via the adapter
  # catalog (reasoning suffixes like "(Thinking)" are label-only, not part of the id).
  @spec parse_antigravity_line(String.t()) :: catalog_entry() | :error
  defp parse_antigravity_line(line) do
    line = String.trim(line)

    cond do
      line == "" -> :error
      String.starts_with?(line, "#") -> :error
      String.starts_with?(line, "Fetching") -> :error
      String.starts_with?(line, "Available") -> :error
      true -> antigravity_catalog_entry(line)
    end
  end

  @spec antigravity_catalog_entry(String.t()) :: catalog_entry() | :error
  defp antigravity_catalog_entry(line) do
    case Antigravity.display_label_to_id(line) do
      id when is_binary(id) -> CatalogEntry.new(id, line)
      nil -> antigravity_id_fallback(line)
    end
  end

  # No display-label match: accept the line only when it (or its parsed id) is
  # itself a known dash-form id, otherwise drop it.
  @spec antigravity_id_fallback(String.t()) :: catalog_entry() | :error
  defp antigravity_id_fallback(line) do
    case parse_id_label_line(line) do
      %{id: id} = entry when is_binary(id) ->
        if id in Antigravity.known_model_ids(), do: entry, else: :error

      :error ->
        if line in Antigravity.known_model_ids(),
          do: CatalogEntry.new(line, line),
          else: :error
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
          CatalogEntry.new(id, label, annotations)
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

  @spec normalize_model_id(String.t()) :: {:ok, String.t()} | {:error, :empty_model}
  defp normalize_model_id(model) do
    case String.trim(model) do
      "" -> {:error, :empty_model}
      id -> {:ok, id}
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
