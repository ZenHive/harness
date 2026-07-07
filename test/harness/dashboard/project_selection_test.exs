defmodule Harness.Dashboard.ProjectSelectionTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.ProjectSelection
  alias Harness.Project

  defp project(name) do
    %Project{name: name, source: {:local, "/tmp/#{name}"}, roadmap_path: "/tmp/#{name}", languages: [:elixir]}
  end

  defp socket(projects) do
    %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, projects: projects}}
  end

  describe "handle_params/2" do
    test "selects the named project from params" do
      assert {:noreply, socket} = ProjectSelection.handle_params(%{"name" => "beta"}, socket([project("alpha")]))
      assert socket.assigns.selected_project == "beta"
    end

    test "falls back to the first registered project" do
      assert {:noreply, socket} =
               ProjectSelection.handle_params(%{}, socket([project("alpha"), project("beta")]))

      assert socket.assigns.selected_project == "alpha"
    end

    test "falls back to an empty name with no projects" do
      assert {:noreply, socket} = ProjectSelection.handle_params(%{}, socket([]))
      assert socket.assigns.selected_project == ""
    end
  end

  describe "selected_project/2" do
    test "finds the project by name" do
      projects = [project("alpha"), project("beta")]
      assert %Project{name: "beta"} = ProjectSelection.selected_project(projects, "beta")
    end

    test "falls back to the first project on an unknown name" do
      projects = [project("alpha"), project("beta")]
      assert %Project{name: "alpha"} = ProjectSelection.selected_project(projects, "missing")
    end

    test "returns nil with no projects" do
      assert ProjectSelection.selected_project([], "any") == nil
    end
  end

  describe "format_checked_at/1" do
    test "formats a UTC timestamp for display" do
      assert ProjectSelection.format_checked_at(~U[2026-07-07 11:22:33Z]) == "2026-07-07 11:22:33 UTC"
    end
  end
end
