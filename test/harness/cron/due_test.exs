defmodule Harness.Cron.DueTest do
  use ExUnit.Case, async: true

  alias Harness.Cron.Due

  test "only valid timestamps at or before the present are due" do
    assert Due.due?(DateTime.to_iso8601(DateTime.utc_now()))
    assert Due.due?("2000-01-01T01:00:00+01:00")
    refute Due.due?("9999-01-01T00:00:00Z")

    for invalid <- [nil, "", "not a date", "2026-02-30T00:00:00Z", 0, %{}] do
      refute Due.due?(invalid)
    end
  end
end
