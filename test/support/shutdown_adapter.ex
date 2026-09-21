defmodule Harness.Test.ShutdownAdapter do
  @moduledoc false
  use Harness.AgentAdapter

  alias Harness.Test.IdentityFakeAdapter

  @spec capabilities() :: Harness.AgentAdapter.Capabilities.t()
  defdelegate capabilities(), to: IdentityFakeAdapter
  @spec rule_channel() :: Harness.AgentAdapter.rule_channel()
  defdelegate rule_channel(), to: IdentityFakeAdapter

  @spec build_command(Harness.AgentAdapter.Invocation.t()) :: {:ok, Harness.AgentAdapter.command()}
  def build_command(invocation) do
    send(Keyword.fetch!(invocation.adapter_opts, :owner), {:invoking, self(), invocation.cwd})

    receive do
      :spawn -> {:ok, {"/bin/sh", ["-c", "exec sleep 300"], []}}
    end
  end
end
