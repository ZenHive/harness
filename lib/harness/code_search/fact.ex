defmodule Harness.CodeSearch.Fact do
  @moduledoc false

  @enforce_keys [:file, :line, :kind, :module, :name, :arity]
  defstruct [
    :file,
    :line,
    :kind,
    :module,
    :name,
    :arity,
    caller: nil,
    callee: nil,
    mass: nil
  ]

  @typedoc "One structural code-search fact returned by `Harness.CodeSearch` queries."
  @type t :: %__MODULE__{
          file: String.t() | nil,
          line: pos_integer() | nil,
          kind: atom(),
          module: String.t() | nil,
          name: String.t() | nil,
          arity: non_neg_integer() | nil,
          caller: String.t() | nil,
          callee: String.t() | nil,
          mass: pos_integer() | nil
        }

  @doc false
  @spec new(keyword()) :: t()
  def new(fields) when is_list(fields), do: struct!(__MODULE__, fields)
end
