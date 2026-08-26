defmodule Harness.Repo.Migrations.ClearAgentsMdFalseApprovalWitnesses do
  @moduledoc false
  use Ecto.Migration

  def up do
    execute("""
    UPDATE run_records
    SET approved_then_found_red = '{}'::jsonb
    WHERE project_name = 'bourse'
      AND inserted_at >= TIMESTAMP '2026-08-14'
      AND inserted_at < TIMESTAMP '2026-08-23'
      AND approved_then_found_red #>> '{cold_check,tail}' ILIKE '%AGENTS.md%'
      AND approved_then_found_red #>> '{cold_check,tail}' NOT ILIKE '%contract-baselines.json%'
    """)
  end

  def down, do: :ok
end
