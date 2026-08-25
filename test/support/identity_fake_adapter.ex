defmodule Harness.Test.IdentityFakeAdapter do
  @moduledoc false

  # Drop-in FakeAdapter that echoes run identity into verdict JSON argv so
  # test doubles satisfy Task 393's identity fence without editing the
  # harness_agent_adapter git dependency.

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Testing.FakeAdapter
  alias Harness.Run.Review

  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  defdelegate capabilities(), to: FakeAdapter

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  defdelegate rule_channel(), to: FakeAdapter

  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{adapter_opts: [command: {:audit_file_discovery, short_sha}]}) do
    script =
      ~S(mkdir -p .audit; printf '%s' "$2" | rmap new --from-stdin --tasks-path roadmap/tasks.toml; ) <>
        ~S|echo discovery > ".audit/$1.md"; git add roadmap .audit; | <>
        ~S|git -c user.email=audit@fake -c user.name=fake-audit commit -q -m "audit($1): filed discovery"|

    fragment = ~S|[[task]]
phase = 23
title = "Audit discovery"
scores = { d = 1, b = 1, u = 1 }
|

    {:ok, {"/bin/sh", ["-c", script, "harness-fake", short_sha, fragment], []}}
  end

  def build_command(%Invocation{} = invocation) do
    with {:ok, {exe, argv, env}} <- FakeAdapter.build_command(invocation) do
      {:ok, {exe, bind_argv(argv, invocation.env), env}}
    end
  end

  @spec review_ratings() :: %{optional(String.t()) => integer()}
  defdelegate review_ratings(), to: FakeAdapter

  @spec review_report(String.t()) :: String.t()
  defdelegate review_report(verdict), to: FakeAdapter

  @doc false
  @spec bind_fields(map(), map()) :: map()
  def bind_fields(fields, env) when is_map(fields) and is_map(env) do
    fields
    |> Map.put("run_id", env_get(env, Review.run_id_env()))
    |> Map.put("review_attempt", env_get(env, Review.review_attempt_env()))
  end

  @doc false
  @spec bind_argv([term()], map() | nil) :: [term()]
  def bind_argv(argv, env) when is_list(argv) and is_map(env) do
    Enum.map(argv, &bind_arg(&1, env))
  end

  def bind_argv(argv, _env), do: argv

  @spec bind_arg(term(), map()) :: term()
  defp bind_arg(arg, env) when is_binary(arg) do
    case Jason.decode(arg) do
      {:ok, %{"verdict" => _verdict} = map} ->
        map |> bind_fields(env) |> Jason.encode!()

      _other ->
        arg
    end
  end

  defp bind_arg(arg, _env), do: arg

  @spec env_get(map(), String.t()) :: String.t()
  defp env_get(env, key) do
    case Map.get(env, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end
end

defmodule Harness.Test.IdentityFakeModelAdapter do
  @moduledoc false

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Testing.FakeModelAdapter
  alias Harness.Test.IdentityFakeAdapter

  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  defdelegate capabilities(), to: FakeModelAdapter

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  defdelegate rule_channel(), to: FakeModelAdapter

  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, {exe, argv, env}} <- FakeModelAdapter.build_command(invocation) do
      {:ok, {exe, IdentityFakeAdapter.bind_argv(argv, invocation.env), env}}
    end
  end
end
