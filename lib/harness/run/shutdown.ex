defmodule Harness.Run.Shutdown do
  @moduledoc false
  use GenServer

  alias Harness.Run.Admission

  @doc false
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  @spec init(keyword()) :: {:ok, keyword()}
  def init(opts) do
    Process.flag(:trap_exit, true)
    {:ok, opts}
  end

  @impl true
  @spec terminate(term(), keyword()) :: :ok
  def terminate(_reason, opts), do: Admission.close(Keyword.fetch!(opts, :admission))
end
