defmodule Harness.Roadmap.MisMarkAuditTest do
  use ExUnit.Case, async: true

  alias Harness.GitFixture
  alias Harness.Roadmap.MisMarkAudit

  test "flags done tasks whose shipped commit touches none of files_to_modify" do
    repo = GitFixture.init_repo()
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/touched.ex"), "defmodule Touched do end\n")
    GitFixture.git!(repo, ["add", "."])
    GitFixture.git!(repo, ["commit", "-q", "-m", "touch expected file"])
    sha = repo |> GitFixture.git!(["rev-parse", "HEAD"]) |> String.trim()

    tasks = [
      %{
        "id" => "1",
        "status" => "done",
        "title" => "Wrong ledger row",
        "shipped_in" => sha,
        "files_to_modify" => ["lib/other.ex"]
      },
      %{
        "id" => "2",
        "status" => "done",
        "title" => "Correct ledger row",
        "shipped_in" => sha,
        "files_to_modify" => ["lib/touched.ex"]
      }
    ]

    assert {:ok, [%{id: "1", title: "Wrong ledger row", shipped_in: ^sha}]} =
             MisMarkAudit.flagged(tasks, repo)
  end

  test "surfaces git errors for invalid shipped_in values" do
    repo = GitFixture.init_repo()

    assert {:error, {:changed_files_failed, "not-a-sha", _reason}} =
             MisMarkAudit.flagged(
               [
                 %{
                   "id" => "1",
                   "status" => "done",
                   "shipped_in" => "not-a-sha",
                   "files_to_modify" => ["lib/x.ex"]
                 }
               ],
               repo
             )
  end
end
