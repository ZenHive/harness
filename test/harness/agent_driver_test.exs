defmodule Harness.AgentDriverTest do
  @moduledoc """
  Locks `Harness.AgentDriver` as the only lib/ caller of the raw adapter Driver.

  A new module that reaches `Harness.AgentAdapter.Driver.run/2,3` fails this
  suite even if today's known call sites stay correct.
  """

  use ExUnit.Case, async: true

  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Outcome
  alias Harness.AgentAdapter.Testing.FakeAdapter
  alias Harness.AgentDriver
  alias Harness.AgentDriverTest.CodexChannelEcho
  alias Harness.GitFixture

  @entry_point AgentDriver
  @raw_driver Harness.AgentAdapter.Driver

  describe "single-entry-point invariant" do
    test "the driver surface advertises AgentDriver, not the raw Driver" do
      modules = Harness.Manifest.modules()

      assert @entry_point in modules
      refute @raw_driver in modules
    end

    test "no MCP/chat tool dispatches to the raw Driver" do
      modules = Harness.Manifest.modules()
      names = Enum.map(Harness.Manifest.mcp_tools(), & &1.name)

      refute "driver-run" in names

      for tool <- Harness.Manifest.mcp_tools() do
        resolved = Harness.Manifest.resolve_tool!(tool, modules)
        refute resolved.module == @raw_driver, "#{tool.name} still targets the raw Driver"
      end
    end

    test "no lib module other than AgentDriver calls Driver.run/2,3" do
      offenders =
        "lib/**/*.ex"
        |> ExAST.search_many(
          run: "Harness.AgentAdapter.Driver.run(...)",
          capture: "&Harness.AgentAdapter.Driver.run/_",
          apply: "apply(Harness.AgentAdapter.Driver, :run, _)",
          capture_fun: "Function.capture(Harness.AgentAdapter.Driver, :run, _)"
        )
        |> Enum.reject(&entry_point_file?/1)
        |> Enum.map(&"#{&1.file}:#{match_line(&1)} (#{&1.pattern})")

      assert offenders == [],
             "raw Driver.run must funnel through #{inspect(@entry_point)}; stray call sites: #{inspect(offenders)}"
    end
  end

  describe "run/3" do
    test "drives a non-codex adapter" do
      cwd = GitFixture.init_repo()

      invocation = %Invocation{
        prompt: "echo",
        cwd: cwd,
        log_tag: "driver",
        adapter_opts: [command: :echo]
      }

      assert {:ok, %Outcome{kind: :exited}} = AgentDriver.run(FakeAdapter, invocation)
    end

    test "a Codex-channel adapter leaves tracked AGENTS.md byte-identical" do
      cwd = tracked_agents_repo()
      before = File.read!(Path.join(cwd, "AGENTS.md"))

      invocation = %Invocation{
        prompt: "echo",
        cwd: cwd,
        log_tag: "driver",
        rule_content: "never change tracked project instructions"
      }

      assert {:ok, %Outcome{kind: :exited}} = AgentDriver.run(CodexChannelEcho, invocation)
      assert File.read!(Path.join(cwd, "AGENTS.md")) == before
      assert GitFixture.git!(cwd, ["diff", "HEAD", "--", "AGENTS.md"]) == ""
    end
  end

  @spec tracked_agents_repo() :: String.t()
  defp tracked_agents_repo do
    repo = GitFixture.init_repo()
    File.write!(Path.join(repo, "CLAUDE.md"), "project rules\n")
    File.write!(Path.join(repo, "AGENTS.md"), "project rules\n")
    GitFixture.git!(repo, ["add", "CLAUDE.md", "AGENTS.md"])
    GitFixture.git!(repo, ["commit", "-q", "-m", "track agents"])
    repo
  end

  @spec entry_point_file?(map()) :: boolean()
  defp entry_point_file?(match) do
    Path.expand(match.file) == Path.expand("lib/harness/agent_driver.ex")
  end

  @spec match_line(map()) :: term()
  defp match_line(%{range: %{start: start}}) when is_map(start), do: start[:line]
  defp match_line(_match), do: "?"
end

defmodule Harness.AgentDriverTest.CodexChannelEcho do
  @moduledoc false

  use Harness.AgentAdapter

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Capabilities
  alias Harness.AgentAdapter.Invocation

  @impl AgentAdapter
  @spec capabilities() :: Capabilities.t()
  def capabilities do
    %Capabilities{session_resume: false, permission_modes: [:autonomous], model_families: []}
  end

  @impl AgentAdapter
  @spec rule_channel() :: AgentAdapter.rule_channel()
  def rule_channel, do: :codex_ephemeral_file

  @impl AgentAdapter
  @spec build_command(Invocation.t()) :: {:ok, AgentAdapter.command()} | {:error, term()}
  def build_command(%Invocation{} = invocation) do
    with {:ok, invocation} <- AgentAdapter.attach_rules(__MODULE__, invocation) do
      {:ok, {"/bin/echo", [AgentAdapter.task_prompt(invocation)], []}}
    end
  end
end
