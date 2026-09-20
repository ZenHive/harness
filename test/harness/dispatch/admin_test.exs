defmodule Harness.Dispatch.AdminTest do
  use ExUnit.Case, async: false

  alias Harness.Dispatch.Admin
  alias Harness.ProjectRegistry

  test "Dispatch registration delegates every public arity and preserves validation" do
    optional = ["focused", 2, [], "main", "full"]

    for count <- 0..5 do
      name = "dispatch-facade-#{System.unique_integer([:positive])}"
      args = [name, "local", "/tmp/#{name}", "/tmp/#{name}", [:elixir]] ++ Enum.take(optional, count)
      assert {:ok, %{name: ^name}} = apply(Harness.Dispatch, :register_project, args)
      on_exit(fn -> ProjectRegistry.unregister(name) end)
      assert {:ok, project} = ProjectRegistry.lookup(name)
      assert project.qa_command == if(count == 5, do: "full")
      assert project.roadmap_target_branch == if(count >= 4, do: "main")
    end

    assert_raise FunctionClauseError, fn ->
      Harness.Dispatch.register_project(nil, "local", "/tmp", "/tmp", [:elixir])
    end
  end

  test "optional registration arities retain their defaults" do
    for extra <- [[], ["focused"], ["focused", 2], ["focused", 2, []]] do
      name = "admin-defaults-#{System.unique_integer([:positive])}"
      args = [name, "local", "/tmp/#{name}", "/tmp/#{name}", [:elixir]] ++ extra
      assert {:ok, %{name: ^name}} = apply(Admin, :register_project, args)
      assert {:ok, project} = ProjectRegistry.lookup(name)
      assert project.qa_command == nil
      assert project.roadmap_target_branch == nil
      assert project.warm_paths == []
      on_exit(fn -> ProjectRegistry.unregister(name) end)
    end
  end

  test "QA command is independent, optional and validated on registration" do
    name = "admin-qa-#{System.unique_integer([:positive])}"

    assert {:ok, %{name: ^name}} =
             Harness.Dispatch.register_project(
               name,
               "local",
               "/tmp",
               "/tmp",
               [:elixir],
               "focused",
               nil,
               [],
               nil,
               "complete"
             )

    assert {:ok, project} = ProjectRegistry.lookup(name)
    assert project.check_command == "focused"
    assert project.qa_command == "complete"
    on_exit(fn -> ProjectRegistry.unregister(name) end)

    assert {:error, {:invalid_project, {:invalid_qa_command, 17}}} =
             Admin.register_project("bad-qa", "local", "/tmp", "/tmp", [:elixir], nil, nil, [], nil, 17)

    assert {:error, {:invalid_project, {:invalid_qa_command, " "}}} =
             Admin.register_project("empty-qa", "local", "/tmp", "/tmp", [:elixir], nil, nil, [], nil, " ")
  end

  test "approving an unknown pending dispatch reports not found" do
    assert {:error, :not_found} = Admin.approve("missing-audit-qa-task")
    assert {:error, :not_found} = Admin.approve("missing-audit-qa-task", nil)
    assert {:ok, %{pending: records}} = Admin.pending()
    assert is_list(records)
    assert {:ok, %{pending: []}} = Admin.pending("missing-audit-qa-project")

    assert {:error, {:invalid_source_type, "invalid"}} =
             Admin.register_project("invalid", "invalid", "/tmp", "/tmp", [:elixir])
  end
end
