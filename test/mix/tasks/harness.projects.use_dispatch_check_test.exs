defmodule Mix.Tasks.Harness.Projects.UseDispatchCheckTest do
  # async: false because it mutates the singleton ProjectRegistry and Mix shell.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Harness.Project
  alias Harness.ProjectRegistry
  alias Mix.Tasks.Harness.Projects.UseDispatchCheck

  setup do
    prior_repo_enabled = Application.get_env(:harness, :repo_enabled)
    previous_shell = Mix.shell()

    Application.put_env(:harness, :repo_enabled, false)
    Mix.shell(Mix.Shell.IO)
    ProjectRegistry.reset()

    on_exit(fn ->
      ProjectRegistry.reset()
      Application.put_env(:harness, :repo_enabled, prior_repo_enabled)
      Mix.shell(previous_shell)
    end)

    :ok
  end

  test "sets Elixir projects to check.dispatch and leaves non-Elixir projects unchanged" do
    :ok = ProjectRegistry.upsert(project("harness", [:elixir], "mix precommit.full"))
    :ok = ProjectRegistry.upsert(project("already", [:elixir], "mix check.dispatch"))
    :ok = ProjectRegistry.upsert(project("rusty", [:rust], "cargo test"))

    output = capture_io(fn -> assert :ok = UseDispatchCheck.run([]) end)

    assert {:ok, %Project{check_command: "mix check.dispatch"}} = ProjectRegistry.lookup("harness")
    assert {:ok, %Project{check_command: "mix check.dispatch"}} = ProjectRegistry.lookup("already")
    assert {:ok, %Project{check_command: "cargo test"}} = ProjectRegistry.lookup("rusty")

    assert output =~ "Updated Elixir projects: harness"
    assert output =~ "Already on dispatch check: already"
    assert output =~ "Skipped non-Elixir projects: rusty"
  end

  test "is idempotent" do
    :ok = ProjectRegistry.upsert(project("harness", [:elixir], "mix check.dispatch"))

    output = capture_io(fn -> assert :ok = UseDispatchCheck.run([]) end)

    assert {:ok, %Project{check_command: "mix check.dispatch"}} = ProjectRegistry.lookup("harness")
    assert output =~ "Updated Elixir projects: none"
    assert output =~ "Already on dispatch check: harness"
  end

  @spec project(String.t(), nonempty_list(atom()), String.t()) :: Project.t()
  defp project(name, languages, check_command) do
    %Project{
      name: name,
      source: {:local, "/tmp/#{name}"},
      roadmap_path: "/tmp/#{name}",
      languages: languages,
      check_command: check_command
    }
  end
end
