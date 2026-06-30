defmodule Harness.CodeSearch.Symbol do
  @moduledoc false

  @typedoc "Parsed components of a qualified Elixir symbol string (e.g. \"MyApp.Mod.fun/2\")."
  @type t :: %__MODULE__{
          module: String.t() | nil,
          name: String.t() | nil,
          arity: non_neg_integer() | nil
        }

  @enforce_keys []
  defstruct [:module, :name, :arity]
end
