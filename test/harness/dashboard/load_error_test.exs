defmodule Harness.Dashboard.LoadErrorTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.LoadError

  test "concurrent source errors and timeouts retain their reasons" do
    reasons =
      [:missing, :malformed, :slow]
      |> Task.async_stream(
        fn
          :missing -> {:error, :roadmap_not_found}
          :malformed -> {:unexpected, "source reply"}
          :slow -> receive do: (:release -> :ok)
        end,
        timeout: 200,
        on_timeout: :kill_task
      )
      |> Enum.map(&LoadError.from_stream/1)

    assert reasons == [:roadmap_not_found, {:unexpected, "source reply"}, :timeout]
  end

  test "killed tasks and unexpected stream failures remain visible" do
    assert LoadError.from_stream({:exit, :kill}) == :timeout
    assert LoadError.from_stream({:exit, {:shutdown, :source_closed}}) == {:shutdown, :source_closed}
    assert LoadError.from_stream(:unavailable) == :unavailable
  end
end
