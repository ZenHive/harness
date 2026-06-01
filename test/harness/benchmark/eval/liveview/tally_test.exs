defmodule Harness.Benchmark.Eval.Liveview.TallyTest do
  use Harness.Dashboard.ConnCase, async: true

  alias Harness.Benchmark.Eval.Liveview.Tally

  test "inc, dec, and reset update the count" do
    {:ok, view, html} = live_isolated(build_conn(), Tally)
    assert html =~ "data-count"
    assert render(view) =~ ">0<"

    assert render_click(view, "inc") =~ ">1<"
    assert render_click(view, "inc") =~ ">2<"
    assert render_click(view, "dec") =~ ">1<"
    assert render_click(view, "reset") =~ ">0<"
  end
end
