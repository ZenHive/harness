defmodule Harness.Dashboard.ErrorHTML do
  @moduledoc """
  Plaintext error renderer for `Harness.Dashboard.Endpoint` (Task 84).

  The dashboard is a single-user dev surface bound to 127.0.0.1, so this
  module deliberately stays minimal: a 500 and a 404 clause that return a
  short string body. It exists to stop the cascade where a 500 in the
  pipeline crashed the error renderer too with
  `(ArgumentError) no "500" html template defined for Harness.Dashboard.ErrorHTML`,
  which replaced the real stack trace with a `Phoenix.Template` crash and
  actively hid the underlying error (e.g. the anubis `:badarg` on
  `/harness/mcp` initialize — see Task 83).

  Wired into the endpoint via the `render_errors` key in `config/config.exs`.
  """

  @doc """
  Renders an error template to a plaintext body. Explicit clauses for the
  500 and 404 status pages; any other template falls back to Phoenix's
  built-in status-message resolution (e.g. `"401.html"` → `"Unauthorized"`).
  """
  @spec render(String.t(), map()) :: String.t()
  def render("500.html", _assigns), do: "Internal Server Error"
  def render("404.html", _assigns), do: "Not Found"

  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end
