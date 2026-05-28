defmodule Harness.Dashboard.ErrorHTMLTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.ErrorHTML

  test "renders the 500 body as plaintext" do
    assert ErrorHTML.render("500.html", %{}) == "Internal Server Error"
  end

  test "renders the 404 body as plaintext" do
    assert ErrorHTML.render("404.html", %{}) == "Not Found"
  end

  test "falls back to Phoenix's status-message resolver for other templates" do
    assert ErrorHTML.render("401.html", %{}) == "Unauthorized"
    assert ErrorHTML.render("403.html", %{}) == "Forbidden"
  end
end
