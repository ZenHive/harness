defmodule Harness do
  @moduledoc """
  Harness — OTP-native AI agent orchestrator.

  Pulls tasks from an rmap roadmap, dispatches them to headless coding agents
  in isolated worktrees, verifies results with the target project's check stack,
  and reports objective verdicts.

  See the README and ROADMAP for architecture and current phase.
  """

  @doc """
  Returns the current version of the harness application.
  """
  @spec version() :: String.t()
  def version do
    :harness |> Application.spec(:vsn) |> to_string()
  end
end
