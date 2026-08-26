defmodule Harness.Repo.Migrations.ClearAgentsMdFalseApprovalWitnesses do
  @moduledoc false
  use Ecto.Migration

  # Task 398: Codex/Pi rule injection prepended harness rules onto tracked
  # AGENTS.md for the whole agent-run window. Audit then wrote cold_check red
  # and witness_cold_check stamped approved_then_found_red on the approved run.
  #
  # Predicate (selection recorded here; irreversible data correction):
  #   project_name = 'bourse'
  #   inserted_at >= 2026-08-14 00:00:00+00
  #   approved_then_found_red #>> '{cold_check,tail}' ILIKE '%AGENTS.md%'
  #   approved_then_found_red #>> '{cold_check,tail}' NOT ILIKE '%contract-baselines.json%'
  #
  # No upper bound: the bug kept accruing after the 2026-08-23 snapshot until
  # this change lands. Dual failures that also cite Deribit
  # contract-baselines.json SHA-256 mismatches keep their fact.
  def up do
    execute("""
    UPDATE run_records
    SET approved_then_found_red = '{}'::jsonb
    WHERE project_name = 'bourse'
      AND inserted_at >= TIMESTAMPTZ '2026-08-14 00:00:00+00'
      AND approved_then_found_red #>> '{cold_check,tail}' ILIKE '%AGENTS.md%'
      AND approved_then_found_red #>> '{cold_check,tail}' NOT ILIKE '%contract-baselines.json%'
    """)
  end

  def down, do: :ok
end
