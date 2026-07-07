defmodule Harness.AgentKPI.TokenTotals do
  @moduledoc false

  @enforce_keys [:input, :output, :total]
  defstruct [:input, :output, :total]

  @typedoc "Integer token counts for one recovery run or an aggregate."
  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          total: non_neg_integer()
        }

  @doc false
  @spec zero() :: t()
  def zero, do: %__MODULE__{input: 0, output: 0, total: 0}

  @doc false
  @spec from_usage(Harness.TokenUsage.t()) :: t()
  def from_usage(%Harness.TokenUsage{} = usage) do
    %__MODULE__{
      input: token_component(usage, :input),
      output: token_component(usage, :output),
      total: token_total(usage)
    }
  end

  @spec token_component(Harness.TokenUsage.t(), :input | :output) :: non_neg_integer()
  defp token_component(%Harness.TokenUsage{} = usage, field) do
    case Map.get(usage, field) do
      count when is_integer(count) -> count
      _other -> 0
    end
  end

  @spec token_total(Harness.TokenUsage.t()) :: non_neg_integer()
  defp token_total(%Harness.TokenUsage{} = usage) do
    case usage.total do
      total when is_integer(total) -> total
      _other -> token_component(usage, :input) + token_component(usage, :output)
    end
  end
end
