defmodule Harness.Dispatch.RunToolTest do
  use ExUnit.Case, async: true

  # A host module exercising the macro end-to-end: `use Descripex` provides the
  # api/3 macro the DSL emits; `import` brings defrun_tool/1 into scope. We pin
  # `name: :status` so the generated function delegates to the real
  # Harness.Run.status/1, whose unknown-run_id path returns {:error, :not_found}
  # without needing a live run — enough to prove delegation + error passthrough.
  defmodule Host do
    @moduledoc false
    use Descripex, namespace: "/run_tool_test"

    import Harness.Dispatch.RunTool

    defrun_tool(
      name: :status,
      summarize: :summarize,
      description: "test status tool",
      run_id_doc: "a run id string",
      returns: "{:ok, map} | {:error, :not_found}"
    )

    defp summarize(value), do: %{wrapped: value}
  end

  describe "defrun_tool/1 expansion" do
    test "generates a one-arg run_id function that delegates and passes :not_found through" do
      assert function_exported?(Host, :status, 1)
      assert {:error, :not_found} = Host.status("__no_such_run__")
    end

    test "emits a descripex api entry for the generated tool" do
      assert function_exported?(Host, :__api__, 0)
      api = Host.__api__()
      assert is_list(api)
      assert Enum.any?(api, &match?(%{name: :status}, &1))
    end
  end

  describe "NimbleOptions schema validation" do
    test "rejects a declaration missing required keys at compile time" do
      assert_raise NimbleOptions.ValidationError, fn ->
        Code.compile_string("""
        defmodule Harness.Dispatch.RunToolTest.BadHost do
          use Descripex, namespace: "/bad"
          import Harness.Dispatch.RunTool
          defrun_tool(name: :status)
        end
        """)
      end
    end
  end
end
