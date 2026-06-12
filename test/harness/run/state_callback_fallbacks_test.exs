defmodule Harness.Run.StateCallbackFallbacksTest do
  use Harness.RunCase, async: true

  describe "state callback fallbacks" do
    test "ignore stale and defensive events without changing state" do
      from = {self(), make_ref()}

      assert :keep_state_and_data = Run.running(:state_timeout, :implementer_idle_timeout, %{})
      assert :keep_state_and_data = Run.recovering(:state_timeout, :recovery_spawn_timeout, %{recovery_run: :set})
      assert :keep_state_and_data = Run.committing(:info, :stale_message, %{})
      assert :keep_state_and_data = Run.committing(:cast, :unexpected, %{})
      assert :keep_state_and_data = Run.done({:timeout, :lifetime}, :lifetime, %{})

      assert {:keep_state_and_data, [{:reply, ^from, {:error, :invalid_state}}]} =
               Run.committing({:call, from}, {:hold, true}, %{})
    end
  end
end
