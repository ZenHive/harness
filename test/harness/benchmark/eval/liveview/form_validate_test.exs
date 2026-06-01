defmodule Harness.Benchmark.Eval.Liveview.FormValidateTest do
  use Harness.Dashboard.ConnCase, async: true

  alias Harness.Benchmark.Eval.Liveview.FormValidate

  test "blank name is invalid and blocks save" do
    {:ok, view, _html} = live_isolated(build_conn(), FormValidate)

    html = render_change(view, "validate", %{"name" => "   "})
    assert html =~ "data-error"
    refute html =~ "data-saved"

    html = render_submit(view, "save", %{"name" => ""})
    assert html =~ "data-error"
    refute html =~ "data-saved"
  end

  test "valid name saves" do
    {:ok, view, _html} = live_isolated(build_conn(), FormValidate)

    html = render_submit(view, "save", %{"name" => "Ada"})
    assert html =~ "data-saved"
    refute html =~ "data-error"
  end
end
