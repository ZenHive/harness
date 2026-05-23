defmodule Harness.AgentRegistryTest do
  use ExUnit.Case, async: false

  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Run
  alias Harness.AgentRegistry

  defmodule NoResumeAdapter do
    @moduledoc false
    def capabilities, do: %Capabilities{session_resume: false}
  end

  defmodule ResumeAdapter do
    @moduledoc false
    def capabilities, do: %Capabilities{session_resume: true}
  end

  setup do
    AgentRegistry.reset()
    :ok
  end

  test "selects the first available adapter that supports all requested capabilities" do
    assert {:ok, ResumeAdapter} =
             AgentRegistry.select([NoResumeAdapter, ResumeAdapter], required_capabilities: [:session_resume])
  end

  test "rejects a request when no available adapter supports a required capability" do
    assert {:error, {:unsupported_capability, :session_resume, [NoResumeAdapter]}} =
             AgentRegistry.select([NoResumeAdapter], required_capabilities: [:session_resume])
  end

  test "marks quota-exhausted adapters unavailable" do
    outcome = %Outcome{
      run: %Run{adapter: ResumeAdapter, port: nil, os_pid: nil, ref: make_ref(), started_at: System.monotonic_time()},
      output: "subscription quota exhausted",
      exit_status: 1,
      kind: :exited
    }

    assert AgentRegistry.quota_exhausted?(outcome)
    assert :ok = AgentRegistry.mark_quota_exhausted(ResumeAdapter, outcome)
    refute AgentRegistry.available?(ResumeAdapter)
    assert [{ResumeAdapter, {:quota_exhausted, :exited}}] = AgentRegistry.list_unavailable()
  end
end
