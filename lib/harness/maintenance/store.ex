defmodule Harness.Maintenance.Store do
  @moduledoc "Transactional maintenance documents; ephemeral when the repository is disabled."
  use Harness.Store.Documents,
    schema: Harness.Maintenance.Document,
    heir: Harness.Maintenance.Store.Heir,
    lock: 444,
    timeout: 3_660_000,
    busy: :already_sweeping
end
