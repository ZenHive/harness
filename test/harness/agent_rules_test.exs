defmodule Harness.AgentRulesTest do
  use ExUnit.Case, async: true

  alias Harness.AgentRules

  describe "render/1" do
    test "includes operational and methodology sections by default" do
      rendered = AgentRules.render()

      assert rendered =~ "Harness operation"
      assert rendered =~ "Development methodology"
      assert rendered =~ "reviewer AI is the gate"
      assert rendered =~ ".harness/question.json"
      assert rendered =~ "HARNESS_RUN_ID"
      assert rendered =~ "HARNESS_IMPLEMENTER_ATTEMPT"
      assert rendered =~ "genuinely ambiguous"
    end

    test "excludes check-expectation thresholds from the injected set" do
      rendered = AgentRules.render()

      refute rendered =~ "Check expectations (reviewer-graded"
      refute rendered =~ "Coverage thresholds"
      refute rendered =~ "mix credo --strict"
    end

    test "can include check expectations when explicitly requested" do
      rendered = AgentRules.render(exclude: [])

      assert rendered =~ "Check expectations (reviewer-graded"
      assert rendered =~ "Coverage thresholds"
    end

    test "supports rendering an explicit section subset" do
      rendered = AgentRules.render(only: [:operational])

      assert rendered =~ "Harness operation"
      refute rendered =~ "Development methodology"
      refute rendered =~ "Elixir conventions"
    end
  end

  describe "render_for_languages/1" do
    test "isolated test-server permission and operator protection reach every language" do
      for languages <- [[:elixir], [:rust]] do
        rendered = AgentRules.render_for_languages(languages)

        assert rendered =~ "Project-owned isolated test servers are allowed"
        assert rendered =~ "isolated test database"
        assert rendered =~ "Never reuse or control an operator or production server"
        assert rendered =~ "success, failure or cancellation"
      end
    end

    test "keeps Elixir sections for Elixir projects" do
      rendered = AgentRules.render_for_languages([:elixir])

      assert rendered =~ "Elixir conventions"
      refute rendered =~ "Coverage thresholds"
    end

    test "drops Elixir sections for non-Elixir projects" do
      rendered = AgentRules.render_for_languages([:rust])

      refute rendered =~ "Elixir conventions"
      refute rendered =~ "Coverage thresholds"
    end
  end

  describe "section_ids/0" do
    test "lists tagged sections from the canonical source" do
      ids = AgentRules.section_ids()

      assert :operational in ids
      assert :methodology in ids
      assert :elixir in ids
      assert :verification_gates in ids
    end
  end
end
