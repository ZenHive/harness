defmodule Harness.Insights.Store do
  @moduledoc "Transactional observation documents; ephemeral when the repository is disabled."
  use Harness.Store.Documents,
    schema: Harness.Insights.Document,
    heir: Harness.Insights.Store.Heir,
    lock: 443,
    timeout: 240_000,
    busy: :already_observing
end
