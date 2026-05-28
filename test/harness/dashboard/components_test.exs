defmodule Harness.Dashboard.ComponentsTest do
  # Unit tests for the shared dashboard chrome components (Task 85). Full page
  # render is browser-verified per Task 50/85; the structural pieces — bucket
  # glyph/label mapping and the persistent navbar/footer markup — are covered
  # here as direct `render_component` calls.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Harness.Dashboard.Components

  describe "bucket_badge/1" do
    test "renders the bucket class, data attribute, glyph, and an explicit label" do
      html = render_component(&Components.bucket_badge/1, bucket: :green, label: "done")

      assert html =~ "bucket-green"
      assert html =~ ~s(data-bucket="green")
      assert html =~ "●"
      assert html =~ ">done</span>"
    end

    test "falls back to the bucket name when no label is given" do
      html = render_component(&Components.bucket_badge/1, bucket: :red)

      assert html =~ "✗"
      assert html =~ ">red</span>"
    end

    test "each bucket carries its own readable glyph" do
      for {bucket, glyph} <- [in_flight: "◯", repairing: "⟳", green: "●", red: "✗"] do
        html = render_component(&Components.bucket_badge/1, bucket: bucket)
        assert html =~ glyph, "expected #{bucket} badge to render #{glyph}"
      end
    end
  end

  describe "navbar/1" do
    test "renders the brand wordmark and the page links" do
      html = render_component(&Components.navbar/1, %{})

      assert html =~ "harness"
      assert html =~ ~s(href="/harness")
      assert html =~ ~s(href="/harness/chat")
      assert html =~ ~s(href="/harness/oban")
    end

    test "does not link to the MCP transport endpoint (not an HTML page)" do
      html = render_component(&Components.navbar/1, %{})
      refute html =~ ~s(href="/harness/mcp")
    end
  end

  describe "footer/1" do
    test "renders the brand mark and tagline" do
      html = render_component(&Components.footer/1, %{})

      assert html =~ "footer-mark"
      assert html =~ "OTP-native task execution"
    end
  end

  describe "page_shell/1" do
    test "wraps the inner block between the navbar and footer" do
      assigns = %{inner_block: inner_block(~s(<p id="page-body">content</p>))}
      html = render_component(&Components.page_shell/1, assigns)

      assert html =~ "navbar"
      assert html =~ ~s(<p id="page-body">content</p>)
      assert html =~ "page-footer"
    end
  end

  # Builds a minimal slot list so `render_slot/1` inside `page_shell/1` renders
  # the supplied raw HTML.
  defp inner_block(html) do
    [%{inner_block: fn _changed, _arg -> Phoenix.HTML.raw(html) end}]
  end
end
