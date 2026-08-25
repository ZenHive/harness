defmodule Harness.Run.WorkerTest do
  use ExUnit.Case, async: true

  alias Ecto.Changeset
  alias Harness.ProjectFixture
  alias Harness.Roadmap.Item
  alias Harness.Run.Worker
  alias Harness.Test.IdentityFakeAdapter, as: FakeAdapter

  test "new_dispatch_job persists a per-run reviewer check command override" do
    project = ProjectFixture.from_repo("/tmp/worker-check-command")
    item = %Item{id: "42", title: "deps", prompt: "prompt", agent: :claude}

    {_run_id, changeset} =
      Worker.new_dispatch_job(project, item, FakeAdapter, check_command: "mix test.json --include integration")

    assert %{"check_command" => "mix test.json --include integration"} =
             changeset |> Changeset.get_change(:args) |> stringify_keys()
  end

  @spec stringify_keys(map()) :: map()
  defp stringify_keys(map) when is_map(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
