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

  describe "transcript_view/1 (Task 87)" do
    test "renders an empty pane when the event list is empty" do
      html = render_component(&Components.transcript_view/1, events: [], agent: :claude)

      assert html =~ ~s(class="transcript-view")
      assert html =~ ~s(data-agent="claude")
      assert html =~ "Waiting for output…"
    end

    test "collapses consecutive :assistant_text into one message body" do
      events = [
        {:assistant_text, %{text: "Hel"}},
        {:assistant_text, %{text: "lo, "}},
        {:assistant_text, %{text: "world!"}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :claude)

      assert html =~ ~s(class="msg msg-assistant")
      assert html =~ "Hello, world!"
      # Only one .msg-body — no per-delta wrapping
      assert html |> String.split(~s(class="msg-body")) |> length() == 2
    end

    test "groups :assistant_tool_use with the matching :tool_result into one <.tool_call>" do
      events = [
        {:assistant_text, %{text: "looking at the file"}},
        {:assistant_tool_use, %{id: "use_1", name: "Read", input: %{"path" => "lib/foo.ex"}}},
        {:tool_result, %{tool_use_id: "use_1", content: "module Foo do …"}},
        {:assistant_text, %{text: "found it"}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :claude)

      # Both text deltas land in the same single message body (one turn).
      assert html =~ "looking at the file"
      assert html =~ "found it"
      assert html =~ ~s(class="tool-call")
      assert html =~ ">Read</span>"
      assert html =~ ~s(data-status="done")
      assert html =~ "module Foo do"
    end

    test "shows status=pending when a tool_use has no matching tool_result yet" do
      events = [
        {:assistant_tool_use, %{id: "use_pending", name: "Bash", input: %{"cmd" => "ls"}}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :claude)

      assert html =~ ~s(data-status="pending")
      assert html =~ ">Bash</span>"
    end

    test "renders :system as an .eyebrow metadata line" do
      events = [{:system, %{kind: :turn_started, data: %{"id" => "turn_1"}}}]

      html = render_component(&Components.transcript_view/1, events: events, agent: :codex)

      assert html =~ ~s(class="eyebrow")
      assert html =~ ~s(data-kind="turn_started")
      assert html =~ ">turn_started</span>"
    end

    test "renders :plain_text as a monospace .plain-chunk card" do
      events = [{:plain_text, %{text: "raw passthrough output\nline 2"}}]

      html = render_component(&Components.transcript_view/1, events: events, agent: :antigravity)

      assert html =~ ~s(class="plain-chunk")
      assert html =~ "raw passthrough output"
      assert html =~ "line 2"
    end

    test "renders :unknown as a muted <details> preserving the raw line" do
      events = [{:unknown, %{raw: ~s({malformed json)}}]

      html = render_component(&Components.transcript_view/1, events: events, agent: :grok)

      assert html =~ ~s(class="transcript-unknown")
      assert html =~ "unknown chunk"
      assert html =~ "{malformed json"
    end

    test "flushes the open assistant turn when a non-message event arrives" do
      events = [
        {:assistant_text, %{text: "first turn"}},
        {:system, %{kind: :result, data: %{"status" => "ok"}}},
        {:assistant_text, %{text: "second turn"}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :claude)

      # Two separate .msg-assistant blocks → the system event split the turn.
      assert html |> String.split(~s(class="msg msg-assistant")) |> length() == 3
      assert html =~ "first turn"
      assert html =~ "second turn"
      assert html =~ ">result</span>"
    end

    test "drops a malformed :tool_result with no preceding :assistant_tool_use" do
      events = [{:tool_result, %{tool_use_id: "orphan", content: "nope"}}]

      html = render_component(&Components.transcript_view/1, events: events, agent: :claude)

      # No tool-call rendered; no orphan message; just the empty-pane sentinel
      # because dropping the unrenderable event leaves zero blocks.
      assert html =~ "Waiting for output…"
      refute html =~ "tool-call"
    end
  end

  describe "eyebrow/1" do
    test "renders the kind label and data-kind attribute" do
      html = render_component(&Components.eyebrow/1, kind: :init, data: %{"x" => 1})

      assert html =~ ~s(data-kind="init")
      assert html =~ ">init</span>"
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
