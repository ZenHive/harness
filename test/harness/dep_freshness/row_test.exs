defmodule Harness.DepFreshness.RowTest do
  use ExUnit.Case, async: true

  alias Harness.DepFreshness.Row

  test "outdated?/1 compares current and latest versions mechanically" do
    refute Row.outdated?(%Row{name: "req", current_version: "0.6.2", latest_version: "0.6.2", constraint_allowed: true})
    assert Row.outdated?(%Row{name: "req", current_version: "0.6.1", latest_version: "0.6.2", constraint_allowed: true})
  end

  test "round-trips JSON persistence maps" do
    row = %Row{name: "req", current_version: "0.6.1", latest_version: "0.6.2", constraint_allowed: true}

    assert Row.from_map(Row.to_map(row)) == row
  end

  test "hydrates atom-keyed maps and defaults malformed values" do
    assert %Row{name: "req", current_version: "", latest_version: "latest", constraint_allowed: false} =
             Row.from_map(%{
               name: :req,
               current_version: nil,
               latest_version: "latest",
               constraint_allowed: "yes"
             })
  end
end
