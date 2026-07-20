defmodule Harness.Roadmap.TaskIdRewriterTest do
  use ExUnit.Case, async: true

  alias Harness.Roadmap.TaskIdRewriter

  test "reassigns only new task blocks whose ids collide with the fetched target" do
    base = """
    schema_version = 2

    [[task]]
    id = "200"
    title = "Existing task"
    status = "pending"

    [[task]]
    id = "201"
    title = "Another existing task"
    status = "pending"
    """

    head = """
    schema_version = 2

    [[task]]
    id = "200"
    title = "Existing task"
    status = "pending"

    [[task]]
    id = "201"
    title = "Another existing task"
    status = "pending"

    [[task]]
    id = "200"
    title = "Newly filed task from stale branch"
    status = "pending"
    """

    assert {:rewritten, rewritten, [%{from: "200", to: "202"}]} =
             TaskIdRewriter.rewrite_collisions(base, head)

    assert rewritten =~ ~s(title = "Existing task")
    assert rewritten =~ ~s(id = "200")
    assert rewritten =~ ~s(id = "202")
    refute duplicate_ids?(rewritten)
  end

  test "leaves non-colliding new task ids unchanged" do
    base = """
    [[task]]
    id = "200"
    title = "Existing task"
    """

    head =
      base <>
        """

        [[task]]
        id = "201"
        title = "New task"
        """

    assert :unchanged = TaskIdRewriter.rewrite_collisions(base, head)
  end

  test "reassigns colliding bare integer task ids without adding quotes" do
    base = """
    [[task]]
    id = 25
    title = "Existing task"

    [[task]]
    id = 26
    title = "Another existing task"
    """

    head = """
    [[task]]
    id = 25
    title = "Existing task"

    [[task]]
    id = 26
    title = "Another existing task"

    [[task]]
    id = 25
    title = "New stale-branch task"
    """

    assert {:rewritten, rewritten, [%{from: "25", to: "27"}]} =
             TaskIdRewriter.rewrite_collisions(base, head)

    assert rewritten =~ ~s(id = 27)
    refute rewritten =~ ~s(id = "27")
    refute duplicate_ids?(rewritten)
  end

  test "normalizes quoted and bare task ids while preserving rewritten line style" do
    base = """
    [[task]]
    id = 25
    title = "Existing bare task"

    [[task]]
    id = "26"
    title = "Existing quoted task"
    """

    head = """
    [[task]]
    id = 25
    title = "Existing bare task"

    [[task]]
    id = "26"
    title = "Existing quoted task"

    [[task]]
    id = "25"
    title = "New quoted task colliding with bare id"

    [[task]]
    id = 26
    title = "New bare task colliding with quoted id"
    """

    expected_rewrites = [%{from: "25", to: "27"}, %{from: "26", to: "28"}]

    assert {:rewritten, rewritten, ^expected_rewrites} =
             TaskIdRewriter.rewrite_collisions(base, head)

    assert rewritten =~ ~s(id = "27")
    assert rewritten =~ ~s(id = 28)
    refute rewritten =~ ~s(id = 27)
    refute rewritten =~ ~s(id = "28")
    refute duplicate_ids?(rewritten)
  end

  test "combines additive sides and renumbers the branch-side collision" do
    base = task_toml("200", "Base task")
    target = base <> task_toml("201", "Target task")
    branch = base <> task_toml("201", "Branch task")

    assert {:ok, resolved, [%{from: "201", to: "202"}]} =
             TaskIdRewriter.resolve_additive_conflict(base, target, branch)

    assert resolved =~ ~s(title = "Target task")
    assert resolved =~ ~s(id = "202")
    assert resolved =~ ~s(title = "Branch task")
  end

  test "refuses a side that edits an existing task block" do
    base = task_toml("200", "Base task")
    target = String.replace(base, "Base task", "Edited task")

    assert {:error, :non_additive} =
             TaskIdRewriter.resolve_additive_conflict(base, target, base <> task_toml("201", "Branch task"))
  end

  defp duplicate_ids?(toml) do
    ids =
      ~r/^\s*id\s*=\s*"(\d+)"\s*$/m
      |> Regex.scan(toml, capture: :all_but_first)
      |> List.flatten()
      |> Kernel.++(
        ~r/^\s*id\s*=\s*(\d+)\s*$/m
        |> Regex.scan(toml, capture: :all_but_first)
        |> List.flatten()
      )

    length(ids) != length(Enum.uniq(ids))
  end

  defp task_toml(id, title) do
    """
    [[task]]
    id = "#{id}"
    title = "#{title}"
    """
  end
end
