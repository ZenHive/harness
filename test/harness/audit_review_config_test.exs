defmodule Harness.AuditReviewConfigTest do
  @moduledoc """
  Config-override behavior for `Harness.AuditReview.default_grader/1`.

  Split out from `Harness.AuditReviewTest` (which is `async: true`) because
  these tests mutate the global `config :harness, :audit_review` application
  env. `async: false` keeps them from running concurrently with any async test
  that reads the same key (e.g. `tools_test.exs` asserts the live default
  pairing), so a mid-test override can't leak across processes.
  """
  # async: false because tests mutate the global :audit_review application env.
  use ExUnit.Case, async: false

  alias Harness.AuditReview

  setup do
    original = Application.get_env(:harness, :audit_review)
    on_exit(fn -> restore_audit_review_env(original) end)
    :ok
  end

  describe "default_grader/1 — config override" do
    test "honors a configured grader_pairs map over the built-in default" do
      # Re-pair Claude → Grok; the in-code default would resolve Claude → Codex.
      Application.put_env(:harness, :audit_review, grader_pairs: %{claude: :grok})

      assert {:ok, Harness.AgentAdapter.Grok} = AuditReview.default_grader(:claude)
      # An implementer absent from the configured map has no default.
      assert {:error, {:no_default_grader, :codex}} = AuditReview.default_grader(:codex)
    end

    test "falls back to the built-in pair when the config key is unset" do
      Application.delete_env(:harness, :audit_review)

      assert {:ok, Harness.AgentAdapter.Codex} = AuditReview.default_grader(:claude)
      assert {:ok, Harness.AgentAdapter.Claude} = AuditReview.default_grader(:codex)
    end
  end

  @spec restore_audit_review_env(keyword() | nil) :: :ok
  defp restore_audit_review_env(nil), do: Application.delete_env(:harness, :audit_review)
  defp restore_audit_review_env(original), do: Application.put_env(:harness, :audit_review, original)
end
