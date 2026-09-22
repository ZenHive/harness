defmodule Harness.Insights.Store do
  @moduledoc "Transactional observation documents; ephemeral when the repository is disabled."

  # A pass runs inside `serialized/1`, so the checkout timeout is the hard ceiling on
  # its duration and must stay above `Harness.Insights.job_timeout_ms/0`, which in turn
  # stays above `pass_timeout_ms/0`. Maintenance.Store holds the same ordering (61min
  # checkout over a 30min sweep deadline).
  use Harness.Store.Documents,
    schema: Harness.Insights.Document,
    heir: Harness.Insights.Store.Heir,
    lock: 443,
    timeout: 1_320_000,
    busy: :already_observing
end
