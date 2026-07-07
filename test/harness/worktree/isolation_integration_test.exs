defmodule Harness.Worktree.IsolationIntegrationTest do
  @moduledoc """
  Live-CLI tripwire for `worktree_isolation: true` adapters.

  Harness trusts the capability and skips the main-checkout pollution snapshot
  for these adapters (`Harness.Run.checkout_snapshot_for_run/1` returns `nil`).
  This suite exercises the real Port + `build_command/1` isolation path in a
  throwaway linked git worktree and asserts writes stay in the worktree.

  **Excluded from the default suite** (`@moduletag :integration`). Run on demand:

      mix test --include integration test/harness/worktree/isolation_integration_test.exs

  Optional per-adapter model overrides (when the default is unavailable):

      HARNESS_ISOLATION_TRIPWIRE_MODEL_CODEX=gpt-5.5 \\
      HARNESS_ISOLATION_TRIPWIRE_MODEL_CURSOR=composer-2.5 \\
        mix test --include integration test/harness/worktree/isolation_integration_test.exs

  Pi is opt-in: set `HARNESS_ISOLATION_TRIPWIRE_MODEL_PI` to a model your local
  `pi` install can run (it drives a self-hosted backend, not a subscription CLI).
  """

  use ExUnit.Case, async: false

  alias Harness.AgentAdapter
  alias Harness.AgentAdapter.Antigravity
  alias Harness.AgentAdapter.Claude
  alias Harness.AgentAdapter.Codex
  alias Harness.AgentAdapter.Cursor
  alias Harness.AgentAdapter.Driver
  alias Harness.AgentAdapter.Grok
  alias Harness.AgentAdapter.Invocation
  alias Harness.AgentAdapter.Pi
  alias Harness.AgentRegistry
  alias Harness.GitFixture
  alias Harness.Worktree.Isolation

  @moduletag :integration
  @moduletag timeout: 900_000

  @marker ".harness-isolation-marker.txt"

  @cli_names %{
    Claude => "claude",
    Codex => "codex",
    Cursor => "cursor-agent",
    Grok => "grok",
    Antigravity => "agy",
    Pi => "pi"
  }

  @default_models %{
    Claude => "sonnet",
    Codex => "gpt-5.5",
    Cursor => "composer-2.5",
    Grok => "grok-composer-2.5-fast",
    Antigravity => "gemini-3.5-flash"
  }

  @total_timeout_ms 180_000
  @idle_timeout_ms 90_000

  test "each worktree_isolation:true adapter with its CLI on PATH isolates writes to the run worktree" do
    isolating = Enum.filter(AgentRegistry.all(), &AgentAdapter.supports?(&1, :worktree_isolation))

    {present, absent} = Enum.split_with(isolating, &tripwire_runnable?/1)

    absent_cli =
      absent
      |> Enum.reject(&opt_in_skipped?/1)
      |> Enum.map(&adapter_label/1)

    absent_opt_in =
      absent
      |> Enum.filter(&opt_in_skipped?/1)
      |> Enum.map(&adapter_label/1)

    if absent_cli != [] do
      IO.puts(:stderr, """
      [worktree isolation tripwire] Skipping adapters whose CLI is not on PATH: #{absent_cli |> Enum.sort() |> Enum.join(", ")}
      """)
    end

    if absent_opt_in != [] do
      IO.puts(:stderr, """
      [worktree isolation tripwire] Skipping opt-in adapters (set #{env_key(Pi)} to include): #{absent_opt_in |> Enum.sort() |> Enum.join(", ")}
      """)
    end

    if present == [] do
      flunk("""
      No worktree_isolation:true adapter CLIs are on PATH — this tripwire exercised zero adapters.

      Install at least one harness agent CLI, then re-run:

          mix test --include integration test/harness/worktree/isolation_integration_test.exs

      Expected binaries: #{Enum.map_join(@cli_names, ", ", fn {_, cli} -> cli end)}
      """)
    end

    for adapter <- present do
      assert_isolated(adapter)
    end
  end

  @spec assert_isolated(module()) :: true
  defp assert_isolated(adapter) do
    repo = GitFixture.init_repo()
    {worktree, branch} = add_linked_worktree!(repo)

    try do
      {:ok, before_porcelain} = Isolation.snapshot(repo)

      invocation = %Invocation{
        prompt: isolation_prompt(),
        cwd: worktree,
        log_tag: "isolation-tripwire",
        model: tripwire_model(adapter)
      }

      case Driver.run(adapter, invocation,
             total_timeout: @total_timeout_ms,
             idle_timeout: @idle_timeout_ms
           ) do
        {:ok, outcome} ->
          marker_path = Path.join(worktree, @marker)

          assert {:ok, after_porcelain} = Isolation.snapshot(repo)

          assert before_porcelain == after_porcelain,
                 """
                 #{adapter_label(adapter)} polluted the main checkout.
                 before:\n#{before_porcelain}
                 after:\n#{after_porcelain}
                 outcome=#{inspect(outcome.kind)}
                 """

          assert File.exists?(marker_path),
                 """
                 #{adapter_label(adapter)} did not create #{@marker} in the worktree (main checkout stayed clean).
                 outcome=#{inspect(outcome.kind)} output_bytes=#{byte_size(outcome.output)}
                 """

          refute File.exists?(Path.join(repo, @marker)),
                 "#{adapter_label(adapter)} leaked #{@marker} into the main checkout"

          assert String.trim(File.read!(marker_path)) == "isolated"

        {:error, {:executable_not_found, executable}} ->
          flunk("""
          #{adapter_label(adapter)} was probed present but `#{executable}` was not found at invoke time.
          Refresh PATH or re-run after `asdf reshim`.
          """)

        {:error, reason} ->
          flunk("#{adapter_label(adapter)} failed to run: #{inspect(reason)}")
      end
    after
      remove_linked_worktree!(repo, worktree, branch)
    end

    true
  end

  @spec isolation_prompt() :: String.t()
  defp isolation_prompt do
    String.trim("""
    Create exactly one new file named `#{@marker}` in the current working directory only \
    (not any parent directory) containing exactly this single line:

    isolated

    Do not modify any other files. Do not run tests or other commands.
    """)
  end

  @spec tripwire_model(module()) :: String.t() | nil
  defp tripwire_model(adapter) do
    cond do
      not AgentAdapter.requires_model?(adapter) ->
        nil

      adapter == Pi ->
        System.fetch_env!(env_key(Pi))

      true ->
        adapter |> env_key() |> System.get_env() || Map.fetch!(@default_models, adapter)
    end
  end

  @spec env_key(module()) :: String.t()
  defp env_key(adapter) do
    {:ok, agent} = AgentRegistry.agent_for_module(adapter)
    "HARNESS_ISOLATION_TRIPWIRE_MODEL_#{agent |> Atom.to_string() |> String.upcase()}"
  end

  @spec tripwire_runnable?(module()) :: boolean()
  defp tripwire_runnable?(adapter) do
    cli_present?(adapter) and not opt_in_skipped?(adapter)
  end

  @spec opt_in_skipped?(module()) :: boolean()
  defp opt_in_skipped?(Pi), do: is_nil(System.get_env(env_key(Pi)))
  defp opt_in_skipped?(_adapter), do: false

  @spec cli_present?(module()) :: boolean()
  defp cli_present?(adapter) do
    case Map.fetch(@cli_names, adapter) do
      {:ok, name} -> not is_nil(System.find_executable(name))
      :error -> false
    end
  end

  @spec adapter_label(module()) :: String.t()
  defp adapter_label(adapter) do
    {:ok, agent} = AgentRegistry.agent_for_module(adapter)
    cli = Map.get(@cli_names, adapter, "?")
    "#{agent} (#{cli})"
  end

  @spec add_linked_worktree!(String.t()) :: {String.t(), String.t()}
  defp add_linked_worktree!(repo) do
    base = GitFixture.tmp_base(name: "isolation-tripwire")
    branch = "harness/isolation-tripwire-#{System.unique_integer([:positive])}"
    worktree = Path.join(base, "wt")
    GitFixture.git!(repo, ["worktree", "add", "-q", worktree, "-b", branch])
    {worktree, branch}
  end

  @spec remove_linked_worktree!(String.t(), String.t(), String.t()) :: :ok
  defp remove_linked_worktree!(repo, worktree, branch) do
    if File.dir?(worktree) do
      GitFixture.git!(repo, ["worktree", "remove", "--force", worktree])
    end

    GitFixture.git!(repo, ["branch", "-D", branch])
    :ok
  rescue
    _ -> :ok
  end
end
