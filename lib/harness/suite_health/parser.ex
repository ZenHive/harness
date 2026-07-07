defmodule Harness.SuiteHealth.Parser do
  @moduledoc false

  @doc false
  @spec failing_tests(String.t(), {String.t(), [String.t()]}) :: [map()]
  def failing_tests(output, {"mix", args}) when is_binary(output) and is_list(args) do
    if Enum.member?(args, "test.json") do
      parse_ex_unit_json(output)
    else
      []
    end
  end

  def failing_tests(output, {"cargo", ["test"]}) when is_binary(output) do
    parse_cargo_failures(output)
  end

  def failing_tests(output, {"go", ["test", "./..."]}) when is_binary(output) do
    parse_go_failures(output)
  end

  def failing_tests(output, {"npm", ["test"]}) when is_binary(output) do
    parse_npm_failures(output)
  end

  def failing_tests(_output, _command), do: []

  @doc false
  @spec passed?(String.t(), {String.t(), [String.t()]}, non_neg_integer()) :: boolean()
  def passed?(output, {"mix", args}, exit_code) when is_binary(output) and is_list(args) do
    if Enum.member?(args, "test.json") do
      case Jason.decode(output) do
        {:ok, %{"summary" => %{"result" => "passed"}}} -> true
        {:ok, %{"summary" => %{"failed" => 0}}} -> true
        {:ok, %{"summary" => %{"result" => "failed"}}} -> false
        {:ok, %{"summary" => %{"failed" => failed}}} when is_integer(failed) and failed > 0 -> false
        _other -> exit_code == 0
      end
    else
      exit_code == 0
    end
  end

  def passed?(_output, _command, exit_code), do: exit_code == 0

  @spec parse_ex_unit_json(String.t()) :: [map()]
  defp parse_ex_unit_json(output) do
    case Jason.decode(output) do
      {:ok, %{"tests" => tests}} when is_list(tests) ->
        tests
        |> Enum.filter(&failed_test?/1)
        |> Enum.map(&ex_unit_failure/1)

      _other ->
        []
    end
  end

  @spec failed_test?(map()) :: boolean()
  defp failed_test?(%{"state" => "failed"}), do: true
  defp failed_test?(%{"state" => "invalid"}), do: true
  defp failed_test?(_test), do: false

  @spec ex_unit_failure(map()) :: map()
  defp ex_unit_failure(test) do
    %{
      name: Map.get(test, "name", "unknown"),
      file: Map.get(test, "file"),
      line: Map.get(test, "line")
    }
  end

  @spec parse_cargo_failures(String.t()) :: [map()]
  defp parse_cargo_failures(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "test ") and String.contains?(&1, "... FAILED")))
    |> Enum.map(fn line ->
      name =
        line
        |> String.trim_leading("test ")
        |> String.split(" ... ")
        |> List.first()
        |> Kernel.||("unknown")

      %{name: name}
    end)
  end

  @spec parse_go_failures(String.t()) :: [map()]
  defp parse_go_failures(output) do
    output
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "--- FAIL:"))
    |> Enum.map(fn line ->
      name =
        line
        |> String.trim_leading("--- FAIL: ")
        |> String.split(" (")
        |> List.first()
        |> Kernel.||("unknown")

      %{name: name}
    end)
  end

  @spec parse_npm_failures(String.t()) :: [map()]
  defp parse_npm_failures(output) do
    if output =~ ~r/\bFAIL\b/i or output =~ ~r/failing/i do
      [%{name: "npm test"}]
    else
      []
    end
  end
end
