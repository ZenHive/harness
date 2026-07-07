defmodule Harness.SuiteHealth.ParserTest do
  use ExUnit.Case, async: true

  alias Harness.SuiteHealth.Parser

  test "parses failing tests from mix test.json output" do
    output = """
    {"summary":{"failed":1,"result":"failed"},"tests":[{"state":"failed","name":"red test","file":"test/demo_test.exs","line":4},{"state":"passed","name":"green","file":"test/demo_test.exs","line":8}]}
    """

    assert [%{name: "red test", file: "test/demo_test.exs", line: 4}] =
             Parser.failing_tests(output, {"mix", ["test.json", "--include", "integration"]})
  end

  test "passed? reads mix test.json summary" do
    output = ~s({"summary":{"failed":0,"result":"passed"},"tests":[]})

    assert Parser.passed?(output, {"mix", ["test.json"]}, 1)
    refute Parser.passed?(~s({"summary":{"failed":1,"result":"failed"},"tests":[]}), {"mix", ["test.json"]}, 0)
  end

  test "parses cargo test failures" do
    output = """
    running 2 tests
    test demo::works ... ok
    test demo::breaks ... FAILED

    failures:
    """

    assert [%{name: "demo::breaks"}] = Parser.failing_tests(output, {"cargo", ["test"]})
  end
end
