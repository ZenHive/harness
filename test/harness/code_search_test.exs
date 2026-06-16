defmodule Harness.CodeSearchTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Harness.Chat.Tools
  alias Harness.CodeSearch
  alias Harness.CodeSearchTest.FakeExograph
  alias Harness.CodeSearchTest.MissingExDNA
  alias Harness.CodeSearchTest.MissingExograph
  alias Harness.Project
  alias Harness.ProjectRegistry

  setup do
    ProjectRegistry.reset()

    cache_root =
      Path.join(
        System.tmp_dir!(),
        "harness_code_search_#{System.unique_integer([:positive])}"
      )

    on_exit(fn ->
      ProjectRegistry.reset()
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
    %{project: project} = fixture_project("code-search-rust", language: :rust)
    assert :ok = ProjectRegistry.register(project)

    log =
      capture_log(fn ->
        assert {:ok, %{status: :skipped, reason: {:unsupported_language, :rust}, facts: []}} =
                 CodeSearch.refresh(project.name, cache_root: cache_root)
      end)

    assert log =~ "CodeSearch skipped"
    assert log =~ "unsupported_language"
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
      language: Keyword.get(opts, :language)
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

  defmodule FakeExograph do
    @moduledoc false

    def index(_paths, _opts), do: {:ok, :fake_index}

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
  end
end
