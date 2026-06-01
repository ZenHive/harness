defmodule Harness.Benchmark.Eval.Elixir.Pipeline do
  @moduledoc false

  @doc false
  @spec parse_int(String.t()) :: {:ok, integer()} | {:error, :negative | :invalid}
  def parse_int(string) when is_binary(string) do
    case Integer.parse(String.trim(string)) do
      {int, ""} when int >= 0 -> {:ok, int}
      {_int, ""} -> {:error, :negative}
      _ -> {:error, :invalid}
    end
  end
end
