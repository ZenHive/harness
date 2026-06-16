defmodule Harness.CodeSearch do
  @moduledoc """
  Structural code-search facts for registered Elixir projects.

  This module is intentionally fact-only: it builds a cached Exograph DuckDB
  index and returns locations for definitions, call edges, and ExDNA duplicate
  fragments. Agents decide what those facts mean.
  """

  use Descripex, namespace: "/code_search"

  alias Harness.Project
  alias Harness.ProjectRegistry

  require Logger

  @default_limit 50
  @default_min_mass 30
  @default_min_occurrences 2
  @default_prefix "code_search"
  @duckdb_threads 1
  @quackdb_wait_timeout_ms 30_000
  @repo_queue_target_ms 60_000
  @repo_queue_interval_ms 120_000
  @repo_timeout_ms 120_000

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
  def definitions(project_name, name, opts \\ []) when is_binary(project_name) and is_binary(name) and is_list(opts) do
    query(project_name, opts, fn index, ctx ->
      case ctx.exograph.search_definitions(index, name, limit: limit(opts)) do
        {:ok, []} -> {:ok, fallback_definitions(ctx.repo_path, name, opts)}
        result -> map_query(result, &definition_fact(&1, ctx))
      end
    end)
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
  defp supported_project(%Project{language: language}) when language in [nil, :elixir], do: :ok

  defp supported_project(%Project{} = project) do
    {:skip, {:unsupported_language, project.language}, project}
  end

  @spec ensure_exograph(Project.t(), keyword()) :: :ok | {:skip, :exograph_unavailable, Project.t()}
  defp ensure_exograph(project, opts), do: ensure_module(:exograph, opts[:exograph_module] || Exograph, project)

  @spec ensure_module(atom(), module(), Project.t() | nil) :: :ok | {:skip, atom(), Project.t() | nil}
  defp ensure_module(reason_base, module, project \\ nil) do
    if Code.ensure_loaded?(module) do
      :ok
    else
      {:skip, :"#{reason_base}_unavailable", project}
    end
  end

  @spec skip(Project.t() | nil, term()) :: {:ok, map()}
  defp skip(project, reason) do
    project_name = if is_nil(project), do: nil, else: project.name

    Logger.warning("CodeSearch skipped project=#{inspect(project_name)} reason=#{inspect(reason)}")
    {:ok, %{status: :skipped, project: project_name, reason: reason, facts: []}}
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
    File.mkdir_p!(Path.dirname(index_path))
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
    with_repo(index_path, opts, fn ctx ->
      case ctx.exograph.index([], index_opts(ctx, false, opts)) do
        {:ok, index} -> fun.(index, ctx)
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  @spec with_repo(String.t(), keyword(), (map() -> term())) :: term()
  defp with_repo(index_path, opts, fun) do
    with :ok <- ensure_module(:quackdb, opts[:quackdb_server_module] || QuackDB.Server),
         :ok <- ensure_module(:exograph_duckdb_repo, opts[:repo_module] || Exograph.DuckDBRepo),
         :ok <- start_app(:ecto_sql),
         :ok <- start_app(:quackdb),
         {:ok, server} <- start_server(index_path, opts) do
      case start_repo(server, opts) do
        {:ok, dynamic_repo} ->
          with_dynamic_repo(server, dynamic_repo, opts, fun)

        {:error, reason} ->
          stop_pid(server)
          {:error, reason}
      end
    end
  end

  @spec with_dynamic_repo(pid(), pid(), keyword(), (map() -> term())) :: term()
  defp with_dynamic_repo(server, dynamic_repo, opts, fun) do
    previous = (opts[:repo_module] || Exograph.DuckDBRepo).get_dynamic_repo()
    (opts[:repo_module] || Exograph.DuckDBRepo).put_dynamic_repo(dynamic_repo)

    try do
      exograph = opts[:exograph_module] || Exograph
      repo = opts[:repo_module] || Exograph.DuckDBRepo
      ctx = %{exograph: exograph, repo: repo, prefix: prefix(opts)}

      fun.(ctx)
    after
      (opts[:repo_module] || Exograph.DuckDBRepo).put_dynamic_repo(previous)
      stop_pid(dynamic_repo)
      stop_pid(server)
    end
  end

  @spec start_app(atom()) :: :ok | {:error, term()}
  defp start_app(app) do
    case Application.ensure_all_started(app) do
      {:ok, _apps} -> :ok
      {:error, reason} -> {:error, reason}
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
      name: :"#{repo}_#{System.unique_integer([:positive])}",
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
  defp prefix(opts), do: Keyword.get(opts, :prefix, @default_prefix)

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
    repo_path
    |> source_paths()
    |> Enum.flat_map(&source_fact/1)
  end

  @spec source_fact(String.t()) :: [map()]
  defp source_fact(path) do
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

  @spec parse_symbol(String.t() | nil) :: %{
          module: String.t() | nil,
          name: String.t() | nil,
          arity: non_neg_integer() | nil
        }
  defp parse_symbol(nil), do: %{module: nil, name: nil, arity: nil}

  defp parse_symbol(symbol) do
    with [left, arity_text] <- String.split(symbol, "/", parts: 2),
         {arity, ""} <- Integer.parse(arity_text),
         [name | module_parts] <- left |> String.split(".") |> Enum.reverse() do
      %{module: module_parts |> Enum.reverse() |> Enum.join("."), name: name, arity: arity}
    else
      _other -> %{module: nil, name: symbol, arity: nil}
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

  @spec newest_source_mtime(String.t()) :: File.time()
  defp newest_source_mtime(repo_path) do
    repo_path
    |> source_paths()
    |> Enum.map(&file_mtime/1)
    |> Enum.max(fn -> {{1970, 1, 1}, {0, 0, 0}} end)
  end

  @spec file_mtime(String.t()) :: File.time()
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
    Enum.each([index_path, index_path <> ".wal"], &File.rm/1)
  end

  @spec stop_pid(pid() | term()) :: :ok
  defp stop_pid(pid) when is_pid(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid, :normal, 5_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_pid(_other), do: :ok

  @spec free_tcp_port!() :: :inet.port_number()
  defp free_tcp_port! do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
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
