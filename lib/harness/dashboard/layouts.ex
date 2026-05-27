defmodule Harness.Dashboard.Layouts do
  @moduledoc """
  Root + app layouts for the harness dashboard (Task 50).

  Embedded inline rather than served from `priv/templates/` so the library
  ships its own minimal HTML chrome without requiring consumers to copy assets.
  Styling is intentionally bare — the dashboard is dev-mode-only for now and
  defers theming.
  """

  use Phoenix.Component

  embed_templates("layouts/*")
end
