defmodule Harness.LandingFixture do
  @moduledoc false

  alias Harness.GitFixture

  @spec origin_task(String.t(), String.t()) :: map()
  def origin_task(origin, id) do
    path = Path.join(GitFixture.tmp_base(), "tasks.toml")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, GitFixture.git!(origin, ["show", "main:roadmap/tasks.toml"]))

    case System.cmd("rmap", ["show", id, "--json", "--tasks-path", path], stderr_to_stdout: true) do
      {output, 0} -> JSON.decode!(output)
      {output, status} -> raise "rmap show failed (#{status}): #{output}"
    end
  end

  @spec roadmap() :: %{origin: String.t(), repo: String.t()}
  def roadmap do
    fixture = GitFixture.init_with_origin(name: "landing-roadmap")
    repo = fixture.repo
    File.mkdir_p!(Path.join(repo, "roadmap"))

    tasks =
      Enum.map_join(["1", "2", "3"], "\n", fn id ->
        """
        [[task]]
        id = "#{id}"
        phase = 1
        bundle = "fixture"
        status = "in_progress"
        title = "Delivery #{id}"
        scores = { d = 2, b = 5, u = 5 }
        body = "Deliver task #{id}."
        created_at = "2026-06-05"
        """
      end)

    File.write!(Path.join(repo, "roadmap/tasks.toml"), """
    schema_version = 2
    project = "landing-fixture"
    default_branch = "main"
    vision = "Landing recovery fixture."

    [phases.1]
    name = "Fixture"
    order = 1
    status = "in_progress"

    [bundles.fixture]
    description = "Fixture"
    order = 1
    phase = 1

    #{tasks}
    """)

    File.write!(Path.join(repo, "ROADMAP.md"), "# Roadmap\n\n<!-- TASKS:BEGIN phase=1 -->\n<!-- TASKS:END -->\n")

    case System.cmd("rmap", ["render", "--tasks-path", Path.join(repo, "roadmap/tasks.toml")], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "rmap render failed (#{status}): #{output}"
    end

    GitFixture.git!(repo, ["add", "roadmap", "ROADMAP.md"])
    GitFixture.git!(repo, ["commit", "-qm", "seed roadmap"])
    GitFixture.git!(repo, ["push", "-q", "origin", "main"])
    fixture
  end
end
