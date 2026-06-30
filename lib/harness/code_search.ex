defmodule Harness.CodeSearch do
  @moduledoc """
  Structural code-search facts for registered Elixir projects.

  This module is intentionally fact-only: it builds a cached Exograph DuckDB
  index and returns locations for definitions, call edges, and ExDNA duplicate
  fragments. Agents decide what those facts mean.
  """

  use Descripex, namespace: "/code_search"

  alias Harness.CodeSearch.Server
  alias Harness.CodeSearch.Symbol
  alias Harness.Project
  alias Harness.ProjectRegistry

  require Logger

  @default_limit 50
  @default_min_mass 30
  @default_min_occurrences 2
  @default_prefix "code_search"
  @duckdb_threads 1
  @definition_cache_table :harness_code_search_definition_facts
  @source_cache_table :harness_code_search_source_facts
  @invalid_prefix_char ~r/[^A-Za-z0-9_]/
  @module_unavailable_reason %{
    exograph: :exograph_unavailable,
    ex_dna: :ex_dna_unavailable
  }
  @definition_kind_by_string %{
    "module" => :module,
    "def" => :def,
    "defp" => :defp,
    "defmacro" => :defmacro,
    "defmacrop" => :defmacrop,
    "defdelegate" => :defdelegate,
    "defcallback" => :defcallback,
    "defmacrocallback" => :defmacrocallback,
    "attribute" => :attribute
  }

  @type fact :: %{
          required(:file) => String.t() | nil,
          required(:line) => pos_integer() | nil,
          required(:kind) => atom(),
          required(:module) => String.t() | nil,
          required(:name) => String.t() | nil,
          required(:arity) => non_neg_integer() | nil,
          optional(:caller) => String.t(),
          optional(:callee) => String.t(),
          optional(:mass) => pos_integer()
        }

  @type result :: {:ok, map()} | {:error, term()}
  @type file_mtime :: :calendar.datetime()

  api(:refresh, "Build or refresh the Exograph DuckDB index for a registered Elixir project.",
    params: [
      project_name: [kind: :value, description: ~s{Registered project slug, e.g. "harness".}],
      opts: [
        kind: :value,
        default: [],
        description:
          "Keyword list. :cache_root overrides ~/.harness/code_search; :force forces rebuild; :duckdb can be :managed or a DuckDB executable path."
      ]
    ],
    returns: %{
      type: :map,
      description: "%{status, project, index_path}; status is :refreshed, :fresh, or :skipped."
    }
  )

  @spec refresh(String.t(), keyword()) :: result()
  def refresh(project_name, opts \\ []) when is_binary(project_name) and is_list(opts) do
    with {:ok, project} <- ProjectRegistry.lookup(project_name),
         :ok <- supported_project(project),
         :ok <- ensure_exograph(project, opts),
         {:ok, repo_path} <- Project.ensure_local_repo(project),
         {:ok, index_path} <- index_path(project, opts) do
      refresh_index(project.name, repo_path, index_path, opts)
    else
      {:skip, reason, project} -> skip(project, reason)
      error -> error
    end
  end

  api(:definitions, "Return definition facts matching a function or module name.",
    params: [
      project_name: [kind: :value, description: "Registered project slug."],
      name: [kind: :value, description: ~s{Name fragment, e.g. "update_user" or "MyApp.Accounts".}],
      opts: [
        kind: :value,
        default: [],
        description: "Keyword list. :limit defaults to 50; :cache_root and :duckdb match refresh/2."
      ]
    ],
    returns: %{type: :map, description: "%{status, project, facts}; facts are definition location maps."}
  )

  @spec definitions(String.t(), String.t(), keyword()) :: result()
  # sobelow_skip ["SQL.Query"] - query SQL uses a sanitized DuckDB table prefix and positional parameters.
  def definitions(project_name, name, opts \\ []) when is_binary(project_name) and is_binary(name) and is_list(opts) do
    query(project_name, opts, &definition_query(&1, name, &2, opts))
  end

  api(:callers, "Return call-edge facts for definitions that call the requested symbol.",
    params: [
      project_name: [kind: :value, description: "Registered project slug."],
      symbol: [kind: :value, description: ~s{Qualified callee, e.g. "MyApp.Accounts.update_user/2".}],
      opts: [kind: :value, default: [], description: "Keyword list. :limit defaults to 50."]
    ],
    returns: %{type: :map, description: "%{status, project, facts}; facts describe caller-side call edges."}
  )

  @spec callers(String.t(), String.t(), keyword()) :: result()
  # sobelow_skip ["SQL.Query"] - query SQL uses a sanitized DuckDB table prefix and positional parameters.
  def callers(project_name, symbol, opts \\ []) when is_binary(project_name) and is_binary(symbol) and is_list(opts) do
    query(project_name, opts, fn index, ctx ->
      case ctx.exograph.search_callers(index, symbol, limit: limit(opts)) do
        {:ok, []} -> {:ok, fallback_call_edges(ctx.repo_path, symbol, :caller, opts)}
        result -> map_query(result, &call_edge_fact(&1, :caller, ctx))
      end
    end)
  end

  api(:callees, "Return call-edge facts for symbols called by the requested caller.",
    params: [
      project_name: [kind: :value, description: "Registered project slug."],
      symbol: [kind: :value, description: ~s{Qualified caller, e.g. "MyApp.Accounts.update_user/2".}],
      opts: [kind: :value, default: [], description: "Keyword list. :limit defaults to 50."]
    ],
    returns: %{type: :map, description: "%{status, project, facts}; facts describe callee-side call edges."}
  )

  @spec callees(String.t(), String.t(), keyword()) :: result()
  # sobelow_skip ["SQL.Query"] - query SQL uses a sanitized DuckDB table prefix and positional parameters.
  def callees(project_name, symbol, opts \\ []) when is_binary(project_name) and is_binary(symbol) and is_list(opts) do
    query(project_name, opts, fn index, ctx ->
      case ctx.exograph.search_callees(index, symbol, limit: limit(opts)) do
        {:ok, []} -> {:ok, fallback_call_edges(ctx.repo_path, symbol, :callee, opts)}
        result -> map_query(result, &call_edge_fact(&1, :callee, ctx))
      end
    end)
  end

  api(:duplicates, "Return ExDNA duplicate-fragment facts for a registered Elixir project.",
    params: [
      project_name: [kind: :value, description: "Registered project slug."],
      opts: [
        kind: :value,
        default: [],
        description: "Keyword list. :min_mass defaults to 30; :min_occurrences defaults to 2."
      ]
    ],
    returns: %{type: :map, description: "%{status, project, facts}; facts describe duplicate fragments."}
  )

  @spec duplicates(String.t(), keyword()) :: result()
  def duplicates(project_name, opts \\ []) when is_binary(project_name) and is_list(opts) do
    with {:ok, project} <- ProjectRegistry.lookup(project_name),
         :ok <- supported_project(project),
         :ok <- ensure_exograph(project, opts),
         :ok <- ensure_module(:ex_dna, opts[:ex_dna_module] || ExDNA, project),
         {:ok, repo_path} <- Project.ensure_local_repo(project),
         {:ok, index_path} <- index_path(project, opts),
         {:ok, _status} <- refresh_index(project.name, repo_path, index_path, opts) do
      report =
        (opts[:ex_dna_module] || ExDNA).analyze(
          paths: [Path.join(repo_path, "lib")],
          min_mass: min_mass(opts),
          min_occurrences: min_occurrences(opts),
          reporters: []
        )

      facts =
        report
        |> Map.fetch!(:clones)
        |> Enum.flat_map(&duplicate_facts/1)

      {:ok, %{status: :ok, project: project.name, facts: facts}}
    else
      {:skip, reason, project} -> skip(project, reason)
      error -> error
    end
  end

  @spec query(String.t(), keyword(), (term(), map() -> {:ok, [fact()]} | {:error, term()})) :: result()
  defp query(project_name, opts, fun) do
    with {:ok, project} <- ProjectRegistry.lookup(project_name),
         :ok <- supported_project(project),
         :ok <- ensure_exograph(project, opts),
         {:ok, repo_path} <- Project.ensure_local_repo(project),
         {:ok, index_path} <- index_path(project, opts),
         {:ok, _status} <- refresh_index(project.name, repo_path, index_path, opts) do
      with_index(index_path, opts, fn index, ctx ->
        ctx = Map.put(ctx, :repo_path, repo_path)

        query_result(fun.(index, ctx), project.name)
      end)
    else
      {:skip, reason, project} -> skip(project, reason)
      error -> error
    end
  end

  @spec query_result({:ok, [fact()]} | {:error, term()}, String.t()) :: result()
  defp query_result({:ok, facts}, project_name), do: {:ok, %{status: :ok, project: project_name, facts: facts}}
  defp query_result({:error, reason}, _project_name), do: {:error, reason}

  @spec supported_project(Project.t()) :: :ok | {:skip, term(), Project.t()}
  defp supported_project(%Project{languages: languages} = project) do
    if :elixir in languages do
      :ok
    else
      {:skip, {:unsupported_languages, languages}, project}
    end
  end

  @spec ensure_exograph(Project.t(), keyword()) :: :ok | {:skip, :exograph_unavailable, Project.t()}
  defp ensure_exograph(project, opts), do: ensure_module(:exograph, opts[:exograph_module] || Exograph, project)

  @spec ensure_module(atom(), module(), Project.t()) :: :ok | {:skip, atom(), Project.t()}
  defp ensure_module(reason_base, module, project) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:skip, Map.fetch!(@module_unavailable_reason, reason_base), project}
    end
  end

  @spec skip(Project.t(), term()) :: {:ok, map()}
  defp skip(%Project{} = project, reason) do
    Logger.warning("CodeSearch skipped project=#{inspect(project.name)} reason=#{inspect(reason)}")
    {:ok, %{status: :skipped, project: project.name, reason: reason, facts: []}}
  end

  @spec refresh_index(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{status: :fresh | :refreshed, index_path: String.t(), project: String.t()}} | {:error, term()}
  defp refresh_index(project_name, repo_path, index_path, opts) do
    if opts[:force] || stale?(repo_path, index_path) do
      repo_path
      |> rebuild_index(index_path, opts)
      |> case do
        :ok -> {:ok, %{status: :refreshed, project: project_name, index_path: index_path}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, %{status: :fresh, project: project_name, index_path: index_path}}
    end
  end

  @spec rebuild_index(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  defp rebuild_index(repo_path, index_path, opts) do
    # sobelow_skip ["Traversal.FileModule"] - index_path is built under the CodeSearch cache root.
    File.mkdir_p!(Path.dirname(index_path))
    Server.close(index_path, opts)
    clear_duckdb_files(index_path)

    index_path
    |> with_repo(opts, fn ctx ->
      paths = source_paths(repo_path)

      case ctx.exograph.index(paths, index_opts(ctx, true, opts)) do
        {:ok, index} ->
          File.touch!(index_path)
          {:ok, index}

        {:error, reason} ->
          {:error, reason}
      end
    end)
    |> case do
      {:ok, _index} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec with_index(String.t(), keyword(), (term(), map() -> term())) :: term()
  defp with_index(index_path, opts, fun) do
    open_index = fn ctx ->
      ctx = Map.put(ctx, :prefix, prefix(opts))

      case ctx.exograph.index([], index_opts(ctx, false, opts)) do
        {:ok, index} -> {:ok, index}
        {:error, reason} -> {:error, reason}
      end
    end

    Server.with_index(index_path, opts, open_index, fn index, ctx ->
      ctx = Map.put(ctx, :prefix, prefix(opts))
      fun.(index, ctx)
    end)
  end

  @spec with_repo(String.t(), keyword(), (map() -> term())) :: term()
  defp with_repo(index_path, opts, fun) do
    Server.with_repo(index_path, opts, fn ctx ->
      ctx = Map.put(ctx, :prefix, prefix(opts))
      fun.(ctx)
    end)
  end

  @spec index_opts(map(), boolean(), keyword()) :: keyword()
  defp index_opts(ctx, migrate?, opts) do
    [
      backend: :duckdb,
      repo: ctx.repo,
      prefix: ctx.prefix,
      migrate?: migrate?,
      bm25?: false,
      duckdb_threads: @duckdb_threads,
      min_mass: min_mass(opts),
      static_atoms: :create
    ]
  end

  @spec prefix(keyword()) :: String.t()
  defp prefix(opts) do
    opts
    |> Keyword.get(:prefix, @default_prefix)
    |> to_string()
    |> String.replace(@invalid_prefix_char, "_")
    |> String.trim_leading("_")
    |> case do
      "" -> @default_prefix
      sanitized -> sanitized
    end
  end

  @spec map_query({:ok, [term()]} | {:error, term()}, (term() -> fact())) :: {:ok, [fact()]} | {:error, term()}
  defp map_query({:ok, values}, mapper), do: {:ok, Enum.map(values, mapper)}
  defp map_query({:error, reason}, _mapper), do: {:error, reason}

  @spec definition_fact(term(), map()) :: fact()
  defp definition_fact(hit, ctx) do
    definition = Map.get(hit, :definition) || Map.get(hit, "definition")
    fragment = Map.get(hit, :fragment) || Map.get(hit, "fragment")

    %{
      file: file_for(definition, fragment, ctx),
      line: Map.get(definition, :line),
      kind: Map.get(definition, :kind),
      module: Map.get(definition, :module),
      name: Map.get(definition, :name),
      arity: Map.get(definition, :arity)
    }
  end

  @spec call_edge_fact(term(), :caller | :callee, map()) :: fact()
  defp call_edge_fact(edge, side, ctx) do
    selected = selected_symbol(edge, side)
    parsed = parse_symbol(selected)

    %{
      file: file_by_id(Map.get(edge, :file_id), ctx),
      line: Map.get(edge, :line),
      kind: :call_edge,
      module: parsed.module,
      name: parsed.name,
      arity: parsed.arity,
      caller: Map.get(edge, :caller_qualified_name),
      callee: Map.get(edge, :callee_qualified_name)
    }
  end

  @spec duplicate_facts(term()) :: [fact()]
  defp duplicate_facts(clone) do
    clone
    |> Map.fetch!(:fragments)
    |> Enum.map(fn fragment ->
      %{
        file: Map.get(fragment, :file),
        line: Map.get(fragment, :line),
        kind: :duplicate_fragment,
        module: nil,
        name: nil,
        arity: nil,
        mass: Map.get(fragment, :mass) || Map.get(clone, :mass)
      }
    end)
  end

  @spec definition_query(term(), String.t(), map(), keyword()) :: {:ok, [fact()]} | {:error, term()}
  defp definition_query(_index, "", ctx, opts), do: all_definition_facts(ctx, opts)

  defp definition_query(index, name, ctx, opts) do
    case ctx.exograph.search_definitions(index, name, limit: limit(opts)) do
      {:ok, []} -> {:ok, fallback_definitions(ctx.repo_path, name, opts)}
      result -> map_query(result, &definition_fact(&1, ctx))
    end
  end

  @spec all_definition_facts(map(), keyword()) :: {:ok, [fact()]} | {:error, term()}
  defp all_definition_facts(ctx, opts) do
    key = {ctx.repo_path, ctx.prefix, newest_source_mtime(ctx.repo_path), limit(opts)}

    case definition_cache_lookup(key) do
      {:ok, facts} -> {:ok, facts}
      :error -> fetch_all_definition_facts(ctx, opts, key)
    end
  end

  @spec fetch_all_definition_facts(map(), keyword(), term()) :: {:ok, [fact()]} | {:error, term()}
  defp fetch_all_definition_facts(ctx, opts, cache_key) do
    sql = ~s|
      SELECT COALESCE(fragment_file.path, definition_file.path) AS file,
             definition.line,
             definition.kind,
             definition.module,
             definition.name,
             definition.arity
      FROM "#{ctx.prefix}_definitions" AS definition
      LEFT JOIN "#{ctx.prefix}_fragments" AS fragment ON fragment.id = definition.fragment_id
      LEFT JOIN "#{ctx.prefix}_files" AS fragment_file ON fragment_file.id = fragment.file_id
      LEFT JOIN "#{ctx.prefix}_files" AS definition_file ON definition_file.id = definition.file_id
      ORDER BY definition.module, definition.name, definition.arity, definition.line
      LIMIT ?
    |

    case ctx.repo.query(sql, [limit(opts)], timeout: :infinity) do
      {:ok, %{rows: []}} ->
        facts = fallback_definitions(ctx.repo_path, "", opts)
        definition_cache_insert(cache_key, facts)
        {:ok, facts}

      {:ok, %{rows: rows}} ->
        facts = Enum.map(rows, &definition_row_fact/1)
        definition_cache_insert(cache_key, facts)
        {:ok, facts}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec definition_row_fact([term()]) :: fact()
  defp definition_row_fact([file, line, kind, module, name, arity]) do
    %{
      file: file,
      line: line,
      kind: definition_kind(kind),
      module: module,
      name: name,
      arity: arity
    }
  end

  @spec definition_kind(atom() | String.t()) :: atom()
  defp definition_kind(kind) when is_atom(kind), do: kind
  defp definition_kind(kind), do: Map.fetch!(@definition_kind_by_string, kind)

  @spec fallback_definitions(String.t(), String.t(), keyword()) :: [fact()]
  defp fallback_definitions(repo_path, name, opts) do
    repo_path
    |> source_facts()
    |> Enum.flat_map(& &1.definitions)
    |> Enum.filter(&definition_match?(&1, name))
    |> Enum.take(limit(opts))
    |> Enum.map(&definition_symbol_fact/1)
  end

  @spec fallback_call_edges(String.t(), String.t(), :caller | :callee, keyword()) :: [fact()]
  defp fallback_call_edges(repo_path, symbol, side, opts) do
    repo_path
    |> source_facts()
    |> Enum.flat_map(&call_edges_for_source/1)
    |> Enum.filter(&call_edge_match?(&1, symbol, side))
    |> Enum.take(limit(opts))
    |> Enum.map(&fallback_call_edge_fact(&1, side))
  end

  @spec source_facts(String.t()) :: [map()]
  defp source_facts(repo_path) do
    key = {repo_path, newest_source_mtime(repo_path)}

    case source_cache_lookup(key) do
      {:ok, facts} ->
        facts

      :error ->
        facts =
          repo_path
          |> source_paths()
          |> Enum.flat_map(&source_fact/1)

        source_cache_insert(key, facts)
        facts
    end
  end

  @spec source_cache_lookup(term()) :: {:ok, [map()]} | :error
  defp source_cache_lookup(key) do
    case :ets.lookup(source_cache_table(), key) do
      [{^key, facts}] -> {:ok, facts}
      [] -> :error
    end
  end

  @spec source_cache_insert(term(), [map()]) :: true
  defp source_cache_insert({repo_path, _mtime} = key, facts) do
    table = source_cache_table()
    # Only the newest-mtime snapshot is ever looked up; evict prior mtimes for
    # this repo so the table can't grow without bound on a long-lived node.
    :ets.match_delete(table, {{repo_path, :_}, :_})
    :ets.insert(table, {key, facts})
  end

  @spec source_cache_table() :: :ets.tid() | atom()
  defp source_cache_table do
    case :ets.whereis(@source_cache_table) do
      :undefined -> create_source_cache_table()
      table -> table
    end
  end

  @spec create_source_cache_table() :: :ets.tid() | atom()
  defp create_source_cache_table do
    :ets.new(@source_cache_table, [:named_table, :public, read_concurrency: true])
  rescue
    ArgumentError -> @source_cache_table
  end

  @spec definition_cache_lookup(term()) :: {:ok, [fact()]} | :error
  defp definition_cache_lookup(key) do
    case :ets.lookup(definition_cache_table(), key) do
      [{^key, facts}] -> {:ok, facts}
      [] -> :error
    end
  end

  @spec definition_cache_insert(term(), [fact()]) :: true
  defp definition_cache_insert({repo_path, prefix, _mtime, limit} = key, facts) do
    table = definition_cache_table()
    # Distinct limits are legitimately distinct result sets; evict only prior
    # mtimes for the same {repo, prefix, limit} so stale snapshots don't pile up.
    :ets.match_delete(table, {{repo_path, prefix, :_, limit}, :_})
    :ets.insert(table, {key, facts})
  end

  @spec definition_cache_table() :: :ets.tid() | atom()
  defp definition_cache_table do
    case :ets.whereis(@definition_cache_table) do
      :undefined -> create_definition_cache_table()
      table -> table
    end
  end

  @spec create_definition_cache_table() :: :ets.tid() | atom()
  defp create_definition_cache_table do
    :ets.new(@definition_cache_table, [:named_table, :public, read_concurrency: true])
  rescue
    ArgumentError -> @definition_cache_table
  end

  @spec source_fact(String.t()) :: [map()]
  defp source_fact(path) do
    # sobelow_skip ["Traversal.FileModule"] - path comes from source_paths/1's lib/test glob under a registered repo.
    with {:ok, source} <- File.read(path),
         {:ok, ast} <- Code.string_to_quoted(source, columns: true, token_metadata: true) do
      symbols_module = Module.concat([ExAST, Symbols])
      definitions = Enum.map(symbols_module.definitions(ast), &Map.put(&1, :file, path))
      references = symbols_module.references(ast)

      [%{file: path, definitions: definitions, references: references}]
    else
      _other -> []
    end
  end

  @spec call_edges_for_source(map()) :: [map()]
  defp call_edges_for_source(%{file: file, definitions: definitions, references: references}) do
    Enum.flat_map(references, fn reference ->
      with :local_call <- Map.get(reference, :kind),
           false <- declaration_reference?(reference, definitions),
           {:ok, caller} <- caller_for_line(definitions, Map.get(reference, :line)),
           {:ok, callee} <- callee_for_reference(reference, definitions, caller) do
        [
          %{
            file: file,
            line: Map.get(reference, :line),
            caller: caller.qualified_name,
            callee: callee
          }
        ]
      else
        _other -> []
      end
    end)
  end

  @spec declaration_reference?(term(), [term()]) :: boolean()
  defp declaration_reference?(reference, definitions) do
    Enum.any?(definitions, fn definition ->
      Map.get(definition, :line) == Map.get(reference, :line) and
        Map.get(definition, :name) == Map.get(reference, :name) and
        Map.get(definition, :arity) == Map.get(reference, :arity)
    end)
  end

  @spec caller_for_line([term()], pos_integer() | nil) :: {:ok, term()} | :error
  defp caller_for_line(definitions, line) when is_integer(line) do
    definitions
    |> Enum.filter(&(Map.get(&1, :kind) in [:def, :defp, :defmacro] and Map.get(&1, :line) <= line))
    |> Enum.max_by(&Map.get(&1, :line), fn -> nil end)
    |> case do
      nil -> :error
      definition -> {:ok, definition}
    end
  end

  defp caller_for_line(_definitions, _line), do: :error

  @spec callee_for_reference(term(), [term()], term()) :: {:ok, String.t()} | :error
  defp callee_for_reference(reference, definitions, caller) do
    reference_name = Map.get(reference, :name)
    reference_arity = Map.get(reference, :arity)

    local =
      Enum.find(definitions, fn definition ->
        Map.get(definition, :module) == Map.get(caller, :module) and
          Map.get(definition, :name) == reference_name and
          Map.get(definition, :arity) == reference_arity
      end)

    cond do
      Map.get(reference, :module) ->
        {:ok, Map.get(reference, :qualified_name)}

      local ->
        {:ok, Map.get(local, :qualified_name)}

      true ->
        :error
    end
  end

  @spec definition_match?(term(), String.t()) :: boolean()
  defp definition_match?(definition, name) do
    contains?(Map.get(definition, :qualified_name), name) or contains?(Map.get(definition, :name), name)
  end

  @spec contains?(term(), String.t()) :: boolean()
  defp contains?(value, needle) do
    value
    |> to_string()
    |> String.contains?(needle)
  end

  @spec definition_symbol_fact(term()) :: fact()
  defp definition_symbol_fact(definition) do
    %{
      file: Map.get(definition, :file),
      line: Map.get(definition, :line),
      kind: Map.get(definition, :kind),
      module: Map.get(definition, :module),
      name: Map.get(definition, :name),
      arity: Map.get(definition, :arity)
    }
  end

  @spec call_edge_match?(map(), String.t(), :caller | :callee) :: boolean()
  defp call_edge_match?(edge, symbol, :caller), do: edge.callee == symbol
  defp call_edge_match?(edge, symbol, :callee), do: edge.caller == symbol

  @spec fallback_call_edge_fact(map(), :caller | :callee) :: fact()
  defp fallback_call_edge_fact(edge, side) do
    selected = if side == :caller, do: edge.caller, else: edge.callee
    parsed = parse_symbol(selected)

    %{
      file: edge.file,
      line: edge.line,
      kind: :call_edge,
      module: parsed.module,
      name: parsed.name,
      arity: parsed.arity,
      caller: edge.caller,
      callee: edge.callee
    }
  end

  @spec file_for(term(), term(), map()) :: String.t() | nil
  defp file_for(definition, fragment, ctx) do
    cond do
      is_map(fragment) and Map.get(fragment, :file) -> Map.get(fragment, :file)
      is_map(definition) -> file_by_id(Map.get(definition, :file_id), ctx)
      true -> nil
    end
  end

  @spec file_by_id(integer() | nil, map()) :: String.t() | nil
  defp file_by_id(nil, _ctx), do: nil

  defp file_by_id(file_id, ctx) when is_integer(file_id) do
    sql = ~s|SELECT path FROM "#{ctx.prefix}_files" WHERE id = ? LIMIT 1|

    case ctx.repo.query(sql, [file_id]) do
      {:ok, %{rows: [[path]]}} -> path
      _other -> nil
    end
  end

  @spec selected_symbol(term(), :caller | :callee) :: String.t() | nil
  defp selected_symbol(edge, :caller), do: Map.get(edge, :caller_qualified_name)
  defp selected_symbol(edge, :callee), do: Map.get(edge, :callee_qualified_name)

  @spec parse_symbol(String.t() | nil) :: Symbol.t()
  defp parse_symbol(nil), do: %Symbol{module: nil, name: nil, arity: nil}

  defp parse_symbol(symbol) do
    with [left, arity_text] <- String.split(symbol, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_text),
         [name | module_parts] <- left |> String.split(".") |> Enum.reverse() do
      %Symbol{module: module_parts |> Enum.reverse() |> Enum.join("."), name: name, arity: arity}
    else
      _other -> %Symbol{module: nil, name: symbol, arity: nil}
    end
  end

  @spec index_path(Project.t(), keyword()) :: {:ok, String.t()}
  defp index_path(project, opts) do
    path =
      opts
      |> Keyword.get_lazy(:cache_root, &default_cache_root/0)
      |> Path.join(safe_project_name(project.name))
      |> Path.join("index.duckdb")

    {:ok, path}
  end

  @spec default_cache_root() :: String.t()
  defp default_cache_root do
    System.user_home!()
    |> Path.join(".harness")
    |> Path.join("code_search")
  end

  @spec stale?(String.t(), String.t()) :: boolean()
  defp stale?(repo_path, index_path) do
    case File.stat(index_path) do
      {:ok, stat} -> newest_source_mtime(repo_path) > stat.mtime
      {:error, _reason} -> true
    end
  end

  @spec newest_source_mtime(String.t()) :: file_mtime()
  defp newest_source_mtime(repo_path) do
    repo_path
    |> source_paths()
    |> Enum.map(&file_mtime/1)
    |> Enum.max(fn -> {{1970, 1, 1}, {0, 0, 0}} end)
  end

  @spec file_mtime(String.t()) :: file_mtime()
  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, stat} -> stat.mtime
      {:error, _reason} -> {{1970, 1, 1}, {0, 0, 0}}
    end
  end

  @spec source_paths(String.t()) :: [String.t()]
  defp source_paths(repo_path) do
    Enum.flat_map(["lib", "test"], fn dir ->
      repo_path
      |> Path.join(dir)
      |> Path.join("**/*.{ex,exs}")
      |> Path.wildcard()
    end)
  end

  @spec clear_duckdb_files(String.t()) :: :ok
  defp clear_duckdb_files(index_path) do
    # sobelow_skip ["Traversal.FileModule"] - removes only the cache index and its adjacent DuckDB WAL file.
    Enum.each([index_path, index_path <> ".wal"], &File.rm/1)
  end

  @spec safe_project_name(String.t()) :: String.t()
  defp safe_project_name(name) do
    String.replace(name, ~r/[^A-Za-z0-9_.-]/, "_")
  end

  @spec limit(keyword()) :: pos_integer()
  defp limit(opts), do: Keyword.get(opts, :limit, @default_limit)

  @spec min_mass(keyword()) :: pos_integer()
  defp min_mass(opts), do: Keyword.get(opts, :min_mass, @default_min_mass)

  @spec min_occurrences(keyword()) :: pos_integer()
  defp min_occurrences(opts), do: Keyword.get(opts, :min_occurrences, @default_min_occurrences)
end

defmodule Harness.CodeSearch.Server do
  @moduledoc """
  Long-lived serialized owner for CodeSearch DuckDB resources.

  The GenServer keeps one QuackDB server plus one dynamic Ecto repo per index
  key. Executing query functions inside the mailbox serializes access to the
  single DuckDB connection while avoiding per-query process boot.
  """

  use GenServer

  @duckdb_threads 1
  @quackdb_wait_timeout_ms 30_000
  @repo_queue_target_ms 60_000
  @repo_queue_interval_ms 120_000
  @repo_timeout_ms 120_000
  @stop_timeout_ms 5_000
  @module_unavailable_reason %{
    quackdb: :quackdb_unavailable,
    exograph_duckdb_repo: :exograph_duckdb_repo_unavailable
  }

  @type resource :: %{server: pid(), repo: pid(), index: term() | nil}
  @type state :: %{resources: %{term() => resource()}}

  @doc "Starts the CodeSearch resource owner."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(opts, :name, __MODULE__))
  end

  @doc "Runs a function with the cached dynamic repo for an index path."
  @spec with_repo(String.t(), keyword(), (map() -> term())) :: term()
  def with_repo(index_path, opts, fun) when is_binary(index_path) and is_list(opts) and is_function(fun, 1) do
    GenServer.call(__MODULE__, {:with_repo, index_path, opts, fun}, :infinity)
  end

  @doc "Runs a function with the cached Exograph index for an index path."
  @spec with_index(String.t(), keyword(), (map() -> {:ok, term()} | {:error, term()}), (term(), map() -> term())) ::
          term()
  def with_index(index_path, opts, open_fun, fun)
      when is_binary(index_path) and is_list(opts) and is_function(open_fun, 1) and is_function(fun, 2) do
    GenServer.call(__MODULE__, {:with_index, index_path, opts, open_fun, fun}, :infinity)
  end

  @doc "Closes a cached resource for an index path."
  @spec close(String.t(), keyword()) :: :ok
  def close(index_path, opts \\ []) when is_binary(index_path) and is_list(opts) do
    GenServer.call(__MODULE__, {:close, index_path, opts}, :infinity)
  end

  @doc "Closes all cached resources."
  @spec close_all() :: :ok
  def close_all, do: GenServer.call(__MODULE__, :close_all, :infinity)

  @impl true
  @spec init(map()) :: {:ok, state()}
  def init(_opts), do: {:ok, %{resources: %{}}}

  @impl true
  def handle_call({:with_repo, index_path, opts, fun}, _from, state) do
    key = resource_key(index_path, opts)

    with :ok <- ensure_module(:quackdb, opts[:quackdb_server_module] || QuackDB.Server),
         :ok <- ensure_module(:exograph_duckdb_repo, opts[:repo_module] || Exograph.DuckDBRepo),
         {:ok, resource, state} <- resource_for(key, index_path, opts, state) do
      {:reply, with_dynamic_repo(resource, opts, fun), state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:skip, reason, _project} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:with_index, index_path, opts, open_fun, fun}, _from, state) do
    key = resource_key(index_path, opts)

    with :ok <- ensure_module(:quackdb, opts[:quackdb_server_module] || QuackDB.Server),
         :ok <- ensure_module(:exograph_duckdb_repo, opts[:repo_module] || Exograph.DuckDBRepo),
         {:ok, resource, state} <- resource_for(key, index_path, opts, state) do
      # Preserve the started server+repo even when the index fails to open: the
      # `with`-rebound `state` is not visible in `else`, so replying there would
      # orphan the live resource. Persist it (index stays nil) so close_all /
      # terminate can reclaim it and the next query retries the open.
      case with_cached_index(resource, opts, open_fun, fun) do
        {:ok, reply, resource} -> {:reply, reply, put_in(state.resources[key], resource)}
        {:error, reason} -> {:reply, {:error, reason}, put_in(state.resources[key], resource)}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
      {:skip, reason, _project} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close, index_path, opts}, _from, state) do
    key = resource_key(index_path, opts)
    {resource, resources} = Map.pop(state.resources, key)
    stop_resource(resource)

    {:reply, :ok, %{state | resources: resources}}
  end

  def handle_call(:close_all, _from, state) do
    Enum.each(state.resources, fn {_key, resource} -> stop_resource(resource) end)

    {:reply, :ok, %{state | resources: %{}}}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.resources, fn {_key, resource} -> stop_resource(resource) end)
    :ok
  end

  @spec resource_for(term(), String.t(), keyword(), state()) :: {:ok, resource(), state()} | {:error, term()}
  defp resource_for(key, index_path, opts, state) do
    case Map.fetch(state.resources, key) do
      {:ok, resource} ->
        {:ok, resource, state}

      :error ->
        with :ok <- start_app(:ecto_sql),
             :ok <- start_app(:quackdb),
             {:ok, resource} <- start_resource(index_path, opts) do
          {:ok, resource, put_in(state.resources[key], resource)}
        end
    end
  end

  @spec start_resource(String.t(), keyword()) :: {:ok, resource()} | {:error, term()}
  defp start_resource(index_path, opts) do
    case start_server(index_path, opts) do
      {:ok, server} ->
        case start_repo(server, opts) do
          {:ok, repo} ->
            {:ok, %{server: server, repo: repo, index: nil}}

          {:error, reason} ->
            stop_pid(server)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec start_server(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_server(index_path, opts) do
    server = opts[:quackdb_server_module] || QuackDB.Server
    token = "harness-code-search-#{System.unique_integer([:positive])}"
    endpoint = "quack:127.0.0.1:#{free_tcp_port!()}"

    server.start_link(
      duckdb: Keyword.get(opts, :duckdb, :managed),
      database: index_path,
      endpoint: endpoint,
      token: token,
      wait_timeout: @quackdb_wait_timeout_ms,
      settings: [threads: @duckdb_threads]
    )
  end

  @spec start_repo(pid(), keyword()) :: {:ok, pid()} | {:error, term()}
  defp start_repo(server, opts) do
    repo = opts[:repo_module] || Exograph.DuckDBRepo
    server_module = opts[:quackdb_server_module] || QuackDB.Server

    repo.start_link(
      name: nil,
      uri: server_module.uri(server),
      token: server_module.token(server),
      pool_size: 1,
      queue_target: @repo_queue_target_ms,
      queue_interval: @repo_queue_interval_ms,
      telemetry_prefix: [:harness, :code_search, :quackdb],
      log: false,
      timeout: @repo_timeout_ms
    )
  end

  @spec with_dynamic_repo(resource(), keyword(), (map() -> term())) :: term()
  defp with_dynamic_repo(resource, opts, fun) do
    repo = opts[:repo_module] || Exograph.DuckDBRepo
    previous = repo.get_dynamic_repo()
    repo.put_dynamic_repo(resource.repo)

    try do
      fun.(%{exograph: opts[:exograph_module] || Exograph, repo: repo})
    after
      repo.put_dynamic_repo(previous)
    end
  end

  @spec with_cached_index(
          resource(),
          keyword(),
          (map() -> {:ok, term()} | {:error, term()}),
          (term(), map() -> term())
        ) ::
          {:ok, term(), resource()} | {:error, term()}
  defp with_cached_index(%{index: nil} = resource, opts, open_fun, fun) do
    with_dynamic_repo(resource, opts, fn ctx ->
      case open_fun.(ctx) do
        {:ok, index} -> {:ok, fun.(index, ctx), %{resource | index: index}}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp with_cached_index(%{index: index} = resource, opts, _open_fun, fun) do
    {:ok, with_dynamic_repo(resource, opts, &fun.(index, &1)), resource}
  end

  @spec stop_resource(resource() | nil) :: :ok
  defp stop_resource(nil), do: :ok

  defp stop_resource(resource) do
    stop_pid(resource.repo)
    stop_pid(resource.server)
  end

  @spec stop_pid(pid()) :: :ok
  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, @stop_timeout_ms)
    :ok
  catch
    :exit, _reason -> :ok
  end

  @spec start_app(atom()) :: :ok | {:error, term()}
  defp start_app(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec ensure_module(atom(), module()) :: :ok | {:skip, atom(), nil}
  defp ensure_module(reason_base, module) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:skip, Map.fetch!(@module_unavailable_reason, reason_base), nil}
    end
  end

  @spec resource_key(String.t(), keyword()) :: term()
  defp resource_key(index_path, opts) do
    # Every opt that changes the opened index/repo must be part of the key, or a
    # cached resource gets reused for an incompatible query context (e.g. a
    # different table prefix or exograph module against the same index_path).
    {
      index_path,
      Keyword.get(opts, :duckdb, :managed),
      Keyword.get(opts, :duckdb_options, []),
      opts[:quackdb_server_module] || QuackDB.Server,
      opts[:repo_module] || Exograph.DuckDBRepo,
      opts[:exograph_module] || Exograph,
      opts[:prefix]
    }
  end

  @spec free_tcp_port!() :: :inet.port_number()
  defp free_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end
end
