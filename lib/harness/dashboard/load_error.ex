defmodule Harness.Dashboard.LoadError do
  @moduledoc "Error unwrapping for concurrent dashboard source reads."

  @doc "Unwraps a task result while preserving the source error and timeout reason."
  @spec from_stream(term()) :: term()
  def from_stream({:ok, {:error, reason}}), do: reason
  def from_stream({:ok, reason}), do: reason
  def from_stream({:exit, :kill}), do: :timeout
  def from_stream({:exit, reason}), do: reason
  def from_stream(reason), do: reason
end
