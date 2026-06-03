defmodule Harness.Dashboard.ConfigInspectorTest do
  @moduledoc """
  Unit coverage for `Harness.Dashboard.ConfigInspector` — the read-only resolver
  behind the Task 127 config-inspector card: section grouping, the
  provenance heuristic (:default / :config / :env), secret redaction, the
  notification-sinks empty-state, and the registered-projects sub-section.

  `async: false` — every assertion reads or mutates global application env
  (`:run`, `:notification_sinks`, …) and the `ProjectRegistry`, which would leak
  across parallel tests.
  """

  use ExUnit.Case, async: false

  alias Harness.Dashboard.ConfigInspector
  alias Harness.Dashboard.Endpoint
  alias Harness.ProjectFixture
  alias Harness.ProjectRegistry

  defp sections, do: ConfigInspector.resolve()

  defp row(sections, title, label) do
    section = Enum.find(sections, &(&1.title == title))
    Enum.find(section.rows, &(&1.label == label))
  end

  describe "resolve/0" do
    test "groups every operator concern into titled sections" do
      titles = Enum.map(sections(), & &1.title)

      for title <- [
            "Dashboard",
            "Run timeouts",
            "Cron polling",
            "Notifications",
            "Result store",
            "Worktree",
            "Retry policy",
            "Database",
            "Registered projects"
          ] do
        assert title in titles
      end
    end

    test "marks a value diverging from the code default as :config provenance" do
      prev = Application.get_env(:harness, :run)
      Application.put_env(:harness, :run, terminal_linger: 9_000)
      on_exit(fn -> restore(:run, prev) end)

      resolved = row(sections(), "Run timeouts", "terminal_linger")

      assert resolved.value == "9 s (9000 ms)"
      assert resolved.provenance == :config
    end

    test "marks an env-var-overridable key as :env when its env var is set" do
      System.put_env("HARNESS_DASHBOARD_PORT", "4321")
      on_exit(fn -> System.delete_env("HARNESS_DASHBOARD_PORT") end)

      resolved = row(sections(), "Dashboard", "port")

      assert resolved.provenance == :env
      assert resolved.env_var == "HARNESS_DASHBOARD_PORT"
    end

    test "redacts the dashboard secret and never leaks the literal into any row" do
      resolved = row(sections(), "Dashboard", "secret_key_base")
      assert resolved.value == "[redacted]"

      secret = Application.get_env(:harness, Endpoint)[:secret_key_base]
      values = for section <- sections(), row <- section.rows, do: row.value

      refute Enum.any?(values, &String.contains?(&1, secret))
    end

    test "humanizes millisecond durations while keeping the raw value for precision" do
      assert row(sections(), "Run timeouts", "total_timeout").value == "30 min (1800000 ms)"
      assert row(sections(), "Run timeouts", "terminal_linger").value == "5 s (5000 ms)"
    end

    test "carries the overriding env var on a row even when it is at its default" do
      # The knob (how to change it) must surface regardless of provenance — the
      # port row names HARNESS_DASHBOARD_PORT even with no override in effect.
      resolved = row(sections(), "Dashboard", "port")
      assert resolved.env_var == "HARNESS_DASHBOARD_PORT"
      assert resolved.provenance == :default
    end

    test "renders an explicit empty-state for no notification sinks" do
      prev = Application.get_env(:harness, :notification_sinks)
      Application.put_env(:harness, :notification_sinks, [])
      on_exit(fn -> restore(:notification_sinks, prev) end)

      assert row(sections(), "Notifications", "sinks").value == "none (silent)"
    end

    test "lists a registered project with its source, roadmap path, and check-command hint" do
      project = ProjectFixture.from_repo("/tmp/harness-config-inspect", name: "config-inspect")
      :ok = ProjectRegistry.register(project)
      on_exit(fn -> ProjectRegistry.unregister(project.name) end)

      resolved = row(sections(), "Registered projects", project.name)

      assert resolved.value =~ "local:/tmp/harness-config-inspect"
      assert resolved.value =~ "roadmap="
      assert resolved.value =~ "check="
    end

    test "renders an empty-state when no projects are registered" do
      # The dev self-project isn't registered in the test node, so the registry is
      # empty unless a test registers one. Assert the empty-state row in that case.
      case ProjectRegistry.list() do
        [] ->
          [row] = Enum.find(sections(), &(&1.title == "Registered projects")).rows
          assert row.label == "No projects registered."

        _registered ->
          :ok
      end
    end
  end

  defp restore(key, nil), do: Application.delete_env(:harness, key)
  defp restore(key, value), do: Application.put_env(:harness, key, value)
end
