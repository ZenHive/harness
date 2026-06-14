defmodule Harness.Dashboard.SettingsComponentsTest do
  # Direct `render_component` coverage for the settings cards extracted from
  # `SettingsLive`'s render. Full-page render is exercised by
  # `Harness.Dashboard.SettingsLiveTest`; these assert each card's structural
  # markup (pills, labels, form events) in isolation.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Harness.Dashboard.SettingsComponents

  describe "cron_autonomy_card/1" do
    test "renders the master toggle, off pill, and disabled status label" do
      autonomy = %{
        master: false,
        status: :disabled,
        projects: [],
        any_effective?: false,
        presets: [{"hourly", "Every hour", "0 * * * *"}],
        active_preset: "hourly"
      }

      html = render_component(&SettingsComponents.cron_autonomy_card/1, autonomy: autonomy)

      assert html =~ "Cron autonomy"
      assert html =~ ~s(data-state="off")
      assert html =~ "polling disabled"
      assert html =~ ~s(phx-click="toggle_master_autonomy")
      assert html =~ "Every hour"
    end

    test "warns when master is on but no project is effective" do
      autonomy = %{
        master: true,
        status: {:enabled, "0 * * * *", :unknown},
        projects: [],
        any_effective?: false,
        presets: [{"hourly", "Every hour", "0 * * * *"}],
        active_preset: "hourly"
      }

      html = render_component(&SettingsComponents.cron_autonomy_card/1, autonomy: autonomy)

      assert html =~ ~s(data-state="armed")
      assert html =~ "no project is enabled"
      assert html =~ "next tick unknown"
    end
  end

  describe "project_autonomy_card/1" do
    test "renders a dispatching pill for an effective project" do
      autonomy = %{projects: [%{name: "demo", project_on: true, effective: true}]}

      html = render_component(&SettingsComponents.project_autonomy_card/1, autonomy: autonomy)

      assert html =~ "demo"
      assert html =~ "dispatching"
      assert html =~ ~s(phx-value-name="demo")
    end

    test "renders the empty state with no projects" do
      html = render_component(&SettingsComponents.project_autonomy_card/1, autonomy: %{projects: []})

      assert html =~ "No projects registered."
    end
  end

  describe "agents_card/1" do
    test "renders enabled + reviewer pills and the not-installed marker" do
      agents = [
        %{name: "codex", label: "Codex", enabled: true, reviewer_eligible: true, installed: true, unavailable: nil},
        %{name: "pi", label: "Pi", enabled: false, reviewer_eligible: false, installed: false, unavailable: nil}
      ]

      html = render_component(&SettingsComponents.agents_card/1, agents: agents)

      assert html =~ "Codex"
      assert html =~ "reviewer eligible"
      assert html =~ "not installed"
      assert html =~ ~s(phx-click="toggle_reviewer_eligible")
    end
  end

  describe "project_reviewers_card/1" do
    test "renders the auto option and a per-project reviewer form" do
      reviewers = %{
        projects: [%{name: "demo", label: "demo", reviewer: nil, reviewer_label: "auto"}],
        options: [%{agent: :codex, name: "codex", label: "Codex"}]
      }

      html = render_component(&SettingsComponents.project_reviewers_card/1, reviewers: reviewers)

      assert html =~ "Project reviewers"
      assert html =~ ~s(phx-submit="set_project_reviewer")
      assert html =~ "Codex"
    end
  end

  describe "dispatch_default_card/1" do
    test "renders the current default agent and the option set" do
      dispatch = %{current: :codex, agents: [:codex, :cursor]}

      html = render_component(&SettingsComponents.dispatch_default_card/1, dispatch: dispatch)

      assert html =~ "Dispatch default"
      assert html =~ ~s(phx-submit="set_default_agent")
      assert html =~ "cursor"
    end
  end

  describe "agent_models_card/1" do
    test "renders a free-text model field when the agent has no catalog" do
      models = [
        %{id: "agent_model__codex", label: "Codex", input_value: "gpt-5.5", placeholder: "agent default", options: :none}
      ]

      html = render_component(&SettingsComponents.agent_models_card/1, agent_models: models)

      assert html =~ "Agent models"
      assert html =~ "gpt-5.5"
      assert html =~ ~s(phx-submit="set_config")
    end
  end

  describe "reviewer_models_card/1" do
    test "renders a catalog dropdown when options are present" do
      models = [
        %{
          id: "reviewer_model__cursor",
          label: "Cursor",
          input_value: "claude-opus-4-8-max",
          placeholder: "inherit",
          options: [%{value: "claude-opus-4-8-max", label: "claude-opus-4-8-max"}]
        }
      ]

      html = render_component(&SettingsComponents.reviewer_models_card/1, reviewer_models: models)

      assert html =~ "Reviewer models"
      assert html =~ "claude-opus-4-8-max"
      assert html =~ "inherit"
    end
  end

  describe "model_catalog_card/1" do
    test "renders add/remove forms and a model count pill" do
      catalogs = [
        %{
          name: "codex",
          label: "Codex",
          refreshable: true,
          models: [%{id: "gpt-5.5", label: "gpt-5.5", dom_id: "gpt-5_5"}]
        }
      ]

      html = render_component(&SettingsComponents.model_catalog_card/1, model_catalogs: catalogs)

      assert html =~ "Model catalog"
      assert html =~ "1 models"
      assert html =~ ~s(phx-submit="add_catalog_model")
      assert html =~ ~s(phx-submit="remove_catalog_model")
      assert html =~ "Refresh from CLI"
    end
  end
end
