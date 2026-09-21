defmodule Harness.Run.StateCallbackFallbacksTest do
  use Harness.RunCase, async: true

  describe "state callback fallbacks" do
    test "ignore stale and defensive events without changing state" do
      from = {self(), make_ref()}
      data = %{shutdown_token: :atomics.new(1, []), result: nil}

      assert :keep_state_and_data = Run.running(:state_timeout, :implementer_idle_timeout, data)

      assert :keep_state_and_data =
               Run.recovering(:state_timeout, :recovery_spawn_timeout, Map.put(data, :recovery_run, :set))

      assert :keep_state_and_data = Run.committing(:info, :stale_message, data)
      assert :keep_state_and_data = Run.committing(:cast, :unexpected, data)
      assert :keep_state_and_data = Run.done({:timeout, :lifetime}, :lifetime, data)

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :invalid_state}}]} =
               Run.committing({:call, from}, {:hold, true}, data)
    end
  end
end
