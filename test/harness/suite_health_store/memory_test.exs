defmodule Harness.SuiteHealthStore.MemoryTest do
  use ExUnit.Case, async: true

  alias Harness.SuiteHealth.Result
  alias Harness.SuiteHealthStore
  alias Harness.SuiteHealthStore.Memory, as: Store

  setup do
    prev = Application.get_env(:harness, :suite_health_store)
    Application.put_env(:harness, :suite_health_store, {Store, scope: :suite_health_memory_test})

    on_exit(fn -> Application.put_env(:harness, :suite_health_store, prev) end)

    :ok
  end

  test "record and fetch round-trip" do
    result =
      Result.build("demo", passed: false, exit_code: 2, command: "mix test.json", failing_tests: [%{name: "red"}])

    store = SuiteHealthStore.configured()
    assert :ok = SuiteHealthStore.record_result(result, store)
    assert {:ok, fetched} = SuiteHealthStore.fetch_result("demo", store)
    assert fetched.passed == false
    assert fetched.exit_code == 2
    assert fetched.failing_tests == [%{name: "red"}]
  end
end
