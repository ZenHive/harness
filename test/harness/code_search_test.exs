defmodule Harness.CodeSearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.Chat.Tools
  alias Harness.CodeSearch
  alias Harness.CodeSearchTest.FakeExograph
  alias Harness.CodeSearchTest.FakeRepo
  alias Harness.CodeSearchTest.FakeServer
  alias Harness.CodeSearchTest.MissingExDNA
  alias Harness.CodeSearchTest.MissingExograph
  alias Harness.Project
  alias Harness.ProjectRegistry

  setup do
    ProjectRegistry.reset()
    previous_test_pid = Application.get_env(:harness, :code_search_test_pid)
    Application.put_env(:harness, :code_search_test_pid, self())

    cache_root =
      Path.join(
        System.tmp_dir!(),
        "harness_code_search_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      ProjectRegistry.reset()
      restore(:code_search_test_pid, previous_test_pid)
      close_code_search_server()
      File.rm_rf(cache_root)
    end)

    {:ok, cache_root: cache_root}
  end

  test "refresh builds a cached index, reuses it while fresh, and rebuilds after source changes", %{
    cache_root: cache_root
  } do
    %{project: project, source_file: source_file} = fixture_project("code-search-refresh")
    assert :ok = ProjectRegistry.register(project)

    opts = [cache_root: cache_root, duckdb: duckdb()]

    assert {:ok, %{status: :refreshed, index_path: index_path}} =
             CodeSearch.refresh(project.name, opts)

    assert File.exists?(index_path)
    first_mtime = File.stat!(index_path).mtime

    assert {:ok, %{status: :fresh, index_path: ^index_path}} =
             CodeSearch.refresh(project.name, opts)

    assert File.stat!(index_path).mtime == first_mtime

    :timer.sleep(1_100)
    File.write!(source_file, "\n\ndef changed(value), do: value\n", [:append])

    assert {:ok, %{status: :refreshed, index_path: ^index_path}} =
             CodeSearch.refresh(project.name, opts)

    assert File.stat!(index_path).mtime > first_mtime
  end

  test "queries return structured facts for definitions, callers, callees, and duplicates", %{
    cache_root: cache_root
  } do
    %{project: project} = fixture_project("code-search-query")
    assert :ok = ProjectRegistry.register(project)

    opts = [cache_root: cache_root, duckdb: duckdb(), min_mass: 4]

    assert {:ok, %{facts: definitions}} =
             CodeSearch.definitions(project.name, "target", opts)

    assert Enum.any?(definitions, &match?(%{kind: :def, module: "Demo.Search", name: "target", arity: 1}, &1))
    assert Enum.all?(definitions, &fact_shape?/1)

    assert {:ok, %{facts: all_definitions}} =
             CodeSearch.definitions(project.name, "", opts)

    assert Enum.any?(all_definitions, &match?(%{kind: :def, module: "Demo.Search", name: "caller", arity: 1}, &1))
    assert Enum.all?(all_definitions, &fact_shape?/1)

    assert {:ok, %{facts: callers}} =
             CodeSearch.callers(project.name, "Demo.Search.target/1", opts)

    assert Enum.any?(callers, &match?(%{module: "Demo.Search", name: "caller", arity: 1}, &1))
    assert Enum.all?(callers, &fact_shape?/1)

    assert {:ok, %{facts: callees}} =
             CodeSearch.callees(project.name, "Demo.Search.caller/1", opts)

    assert Enum.any?(callees, &match?(%{module: "Demo.Search", name: "target", arity: 1}, &1))
    assert Enum.all?(callees, &fact_shape?/1)

    assert {:ok, %{facts: duplicates}} =
             CodeSearch.duplicates(project.name, cache_root: cache_root, min_mass: 5, min_occurrences: 2)

    assert Enum.any?(duplicates, &match?(%{kind: :duplicate_fragment, mass: mass} when mass >= 5, &1))
    assert Enum.all?(duplicates, &fact_shape?/1)
  end

  test "logs and skips when Exograph is unavailable", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-missing-exograph")
    assert :ok = ProjectRegistry.register(project)

    log =
      capture_log(fn ->
        assert {:ok, %{status: :skipped, reason: :exograph_unavailable, facts: []}} =
                 CodeSearch.definitions(project.name, "target",
                   cache_root: cache_root,
                   exograph_module: MissingExograph
                 )
      end)

    assert log =~ "CodeSearch skipped"
    assert log =~ "exograph_unavailable"
  end

  test "logs and skips non-Elixir projects", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-rust", languages: [:rust])
    assert :ok = ProjectRegistry.register(project)

    log =
      capture_log(fn ->
        assert {:ok, %{status: :skipped, reason: {:unsupported_languages, [:rust]}, facts: []}} =
                 CodeSearch.refresh(project.name, cache_root: cache_root)
      end)

    assert log =~ "CodeSearch skipped"
    assert log =~ "unsupported_language"
  end

  test "supports mixed projects that include Elixir", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-mixed", languages: [:elixir, :rust])
    assert :ok = ProjectRegistry.register(project)

    assert {:ok, %{status: :refreshed}} =
             CodeSearch.refresh(project.name, cache_root: cache_root, duckdb: duckdb())
  end

  test "CodeSearch tools are exposed through the chat/MCP registry" do
    registry = Tools.build()

    for tool <-
          ~w(code_search-refresh code_search-definitions code_search-callers code_search-callees code_search-duplicates) do
      assert Map.has_key?(registry, tool), "expected #{tool} in Chat.Tools registry"
    end
  end

  test "queries normalize non-empty Exograph results without fallback", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-primary")
    assert :ok = ProjectRegistry.register(project)

    opts = [cache_root: cache_root, exograph_module: FakeExograph, duckdb: duckdb()]

    assert {:ok, %{facts: [%{file: "fake.ex", kind: :def, module: "Fake", name: "found", arity: 0}]}} =
             CodeSearch.definitions(project.name, "found", opts)

    assert {:ok, %{facts: [%{kind: :call_edge, module: "Fake", name: "caller", arity: 0}]}} =
             CodeSearch.callers(project.name, "Fake.target/0", opts)

    assert {:ok, %{facts: [%{kind: :call_edge, module: "Fake", name: "target", arity: 0}]}} =
             CodeSearch.callees(project.name, "Fake.caller/0", opts)
  end

  test "queries reuse the same server and repo while the index is fresh", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-reuse")
    assert :ok = ProjectRegistry.register(project)

    opts = fake_lifecycle_opts(cache_root)

    assert {:ok, %{facts: [%{name: "found"}]}} = CodeSearch.definitions(project.name, "found", opts)
    assert {:ok, %{facts: [%{name: "found"}]}} = CodeSearch.definitions(project.name, "found", opts)

    assert_receive {:fake_server_started, server_pid}
    assert_receive {:fake_repo_started, repo_pid}
    assert_receive {:fake_repo_opts, opts}
    assert Keyword.fetch!(opts, :name) == nil
    refute_receive {:fake_server_started, _another_server_pid}
    refute_receive {:fake_repo_started, _another_repo_pid}

    assert_receive {:fake_index, ^repo_pid, true}
    assert_receive {:fake_index, ^repo_pid, false}
    refute_receive {:fake_index, ^repo_pid, false}
    assert is_pid(server_pid)
  end

  test "queries rebuild a stale index before reusing it", %{cache_root: cache_root} do
    %{project: project, source_file: source_file} = fixture_project("code-search-stale-query")
    assert :ok = ProjectRegistry.register(project)

    opts = fake_lifecycle_opts(cache_root)

    assert {:ok, %{facts: [%{name: "found"}]}} = CodeSearch.definitions(project.name, "found", opts)

    :timer.sleep(1_100)
    File.write!(source_file, "\n\ndef changed(value), do: value\n", [:append])

    assert {:ok, %{facts: [%{name: "found"}]}} = CodeSearch.definitions(project.name, "found", opts)

    assert Enum.count(received_events(), &match?({:fake_index, _repo_pid, true}, &1)) == 2
  end

  test "sanitizes custom DuckDB table prefixes before querying", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-prefix")
    assert :ok = ProjectRegistry.register(project)

    opts = Keyword.put(fake_lifecycle_opts(cache_root), :prefix, ~s|bad"; DROP TABLE files; --|)

    assert {:ok, %{facts: facts}} = CodeSearch.definitions(project.name, "", opts)
    assert Enum.any?(facts, &match?(%{module: "Demo.Search", name: "target"}, &1))

    assert_receive {:fake_query, sql, [_limit], [timeout: :infinity]}
    refute sql =~ ";"
    refute sql =~ "DROP TABLE"
    assert sql =~ ~s|FROM "bad___DROP_TABLE_files_____definitions"|
  end

  test "duplicates logs and skips when ExDNA is unavailable", %{cache_root: cache_root} do
    %{project: project} = fixture_project("code-search-missing-ex-dna")
    assert :ok = ProjectRegistry.register(project)

    log =
      capture_log(fn ->
        assert {:ok, %{status: :skipped, reason: :ex_dna_unavailable, facts: []}} =
                 CodeSearch.duplicates(project.name,
                   cache_root: cache_root,
                   ex_dna_module: MissingExDNA
                 )
      end)

    assert log =~ "CodeSearch skipped"
    assert log =~ "ex_dna_unavailable"
  end

  test "unknown projects return the registry error" do
    assert {:error, {:unknown_project, "missing"}} = CodeSearch.refresh("missing")
  end

  defp fixture_project(name, opts \\ []) do
    root = Path.join(System.tmp_dir!(), "#{name}_#{System.unique_integer([:positive])}")
    lib = Path.join(root, "lib")
    File.mkdir_p!(lib)

    source_file = Path.join(lib, "demo_search.ex")

    File.write!(source_file, """
    defmodule Demo.Search do
      def caller(value) do
        target(value)
      end

      def target(value) do
        normalize(value)
      end

      def duplicate_one(value) do
        value
        |> String.trim()
        |> String.downcase()
      end

      def duplicate_two(value) do
        value
        |> String.trim()
        |> String.downcase()
      end

      defp normalize(value), do: value
    end
    """)

    project = %Project{
      name: name,
      source: {:local, root},
      roadmap_path: Path.join(root, "roadmap/tasks.toml"),
      languages: Keyword.get(opts, :languages, [Keyword.get(opts, :language, :elixir)])
    }

    %{project: project, root: root, source_file: source_file}
  end

  defp fact_shape?(fact) do
    is_map(fact) and
      Map.has_key?(fact, :file) and
      Map.has_key?(fact, :line) and
      Map.has_key?(fact, :kind) and
      Map.has_key?(fact, :module) and
      Map.has_key?(fact, :name) and
      Map.has_key?(fact, :arity)
  end

  defp duckdb do
    case System.get_env("QUACKDB_TEST_DUCKDB") do
      "managed" -> :managed
      path when is_binary(path) and path != "" -> path
      _other -> :managed
    end
  end

  defp fake_lifecycle_opts(cache_root) do
    [
      cache_root: cache_root,
      exograph_module: FakeExograph,
      quackdb_server_module: FakeServer,
      repo_module: FakeRepo
    ]
  end

  defp received_events(events \\ []) do
    receive do
      event -> received_events([event | events])
    after
      0 -> Enum.reverse(events)
    end
  end

  defp close_code_search_server do
    module = Harness.CodeSearch.Server

    if Code.ensure_loaded?(module) and function_exported?(module, :close_all, 0) do
      module.close_all()
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)

  defmodule FakeExograph do
    @moduledoc false

    def index(_paths, opts) do
      repo = Keyword.fetch!(opts, :repo)
      send_event({:fake_index, repo.get_dynamic_repo(), Keyword.fetch!(opts, :migrate?)})
      {:ok, :fake_index}
    end

    def search_definitions(:fake_index, _name, _opts) do
      {:ok,
       [
         %{
           definition: %{line: 1, kind: :def, module: "Fake", name: "found", arity: 0},
           fragment: %{file: "fake.ex"}
         }
       ]}
    end

    def search_callers(:fake_index, _symbol, _opts) do
      {:ok,
       [
         %{
           file_id: nil,
           line: 2,
           caller_qualified_name: "Fake.caller/0",
           callee_qualified_name: "Fake.target/0"
         }
       ]}
    end

    def search_callees(:fake_index, _symbol, _opts) do
      search_callers(:fake_index, nil, [])
    end

    defp send_event(event), do: send(Application.fetch_env!(:harness, :code_search_test_pid), event)
  end

  defmodule FakeServer do
    @moduledoc false

    def start_link(_opts) do
      fn -> :server end
      |> Agent.start_link()
      |> tap(fn
        {:ok, pid} -> send_event({:fake_server_started, pid})
        _other -> :ok
      end)
    end

    def uri(pid), do: "http://fake-server/#{inspect(pid)}"
    def token(pid), do: "fake-token-#{inspect(pid)}"

    defp send_event(event), do: send(Application.fetch_env!(:harness, :code_search_test_pid), event)
  end

  defmodule FakeRepo do
    @moduledoc false

    def start_link(opts) do
      fn -> :repo end
      |> Agent.start_link()
      |> tap(fn
        {:ok, pid} ->
          send_event({:fake_repo_started, pid})
          send_event({:fake_repo_opts, opts})

        _other ->
          :ok
      end)
    end

    def get_dynamic_repo, do: Process.get({__MODULE__, :dynamic_repo}, __MODULE__)

    def put_dynamic_repo(dynamic_repo) do
      Process.put({__MODULE__, :dynamic_repo}, dynamic_repo) || __MODULE__
    end

    def query(_sql, _params), do: {:ok, %{rows: []}}

    def query(sql, params, opts) do
      tap({:ok, %{rows: []}}, fn _result -> send_event({:fake_query, sql, params, opts}) end)
    end

    defp send_event(event), do: send(Application.fetch_env!(:harness, :code_search_test_pid), event)
  end
end
