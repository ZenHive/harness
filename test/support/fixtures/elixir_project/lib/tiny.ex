defmodule Tiny do
  @moduledoc false

  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(map) when is_map(map), do: Jason.encode(map)
end
