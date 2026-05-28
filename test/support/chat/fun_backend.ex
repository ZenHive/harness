defmodule Harness.Chat.FunBackend do
  @moduledoc false
  @behaviour Harness.Chat.Backend

  alias Harness.Chat.Backend

  @impl Backend
  @spec stream(Backend.request(), Backend.stream_callback(), keyword()) ::
          {:ok, map()} | {:error, Backend.error()}
  def stream(request, callback, opts) do
    fun = Keyword.fetch!(opts, :fun)
    fun.(request, callback, opts)
  end
end
