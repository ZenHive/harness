defmodule Harness.DepFreshness.Provider do
  @moduledoc """
  Behaviour for per-language dependency freshness providers.

  Each provider returns raw rows — name, current, latest, constraint_allowed —
  without judging which upgrades to perform.
  """

  alias Harness.DepFreshness.Row
  alias Harness.Project

  @doc "Scans one project checkout and returns raw dependency freshness rows."
  @callback scan(Project.t(), String.t(), keyword()) ::
              {:ok, [Row.t()]} | {:error, term()} | {:skipped, term()}
end
