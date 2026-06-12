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

    test "coalesces consecutive :thought tokens into one reasoning card" do
      # Grok streams chain-of-thought token-by-token — one :system/:thought per
      # token. Pre-fix these rendered as a wall of empty eyebrow rows (the
      # token text was dropped); they must fold into a single card carrying the
      # concatenated text.
      events =
        for frag <- ["Run", "Supervisor", ".start", "_run"],
            do: {:system, %{kind: :thought, data: %{text: frag}}}

      html = render_component(&Components.transcript_view/1, events: events, agent: :grok)

      assert html |> String.split(~s(class="transcript-thought")) |> length() == 2
      assert html =~ "RunSupervisor.start_run"
      assert html =~ ">reasoning</summary>"
      # Not the old empty-eyebrow rendering.
      refute html =~ ~s(data-kind="thought")
    end

    test "a thought block is flushed when assistant text follows" do
      events = [
        {:system, %{kind: :thought, data: %{text: "let me check"}}},
        {:assistant_text, %{text: "here is the answer"}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :grok)

      assert html =~ ~s(class="transcript-thought")
      assert html =~ "let me check"
      assert html =~ ~s(class="msg msg-assistant")
      assert html =~ "here is the answer"
    end

    test "a thought between two assistant turns splits the turns" do
      events = [
        {:assistant_text, %{text: "first"}},
        {:system, %{kind: :thought, data: %{text: "reconsidering"}}},
        {:assistant_text, %{text: "second"}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :grok)

      assert html |> String.split(~s(class="msg msg-assistant")) |> length() == 3
      assert html |> String.split(~s(class="transcript-thought")) |> length() == 2
      assert html =~ "reconsidering"
    end
  end

  describe "eyebrow/1" do
    test "renders the kind label and data-kind attribute" do
      html = render_component(&Components.eyebrow/1, kind: :init, data: %{"x" => 1})

      assert html =~ ~s(data-kind="init")
      assert html =~ ">init</span>"
    end
  end

  describe "json_tree/1" do
    test "renders atom, nil, and opaque values as typed leaves" do
      html = render_component(&Components.json_tree/1, value: %{atom: :ok, nil: nil, date: ~D[2026-06-12]})

      assert html =~ ~s(class="leaf-atom")
      assert html =~ ":ok"
      assert html =~ ~s(class="leaf-nil")
      assert html =~ "null"
      assert html =~ ~s(class="leaf-other")
      assert html =~ "~D[2026-06-12]"
    end

    test "renders list, number, and boolean leaves" do
      html = render_component(&Components.json_tree/1, value: [1, true, []])

      assert html =~ ~s(class="leaf-number")
      assert html =~ ">1</span>"
      assert html =~ ~s(class="leaf-bool")
      assert html =~ "true"
      assert html =~ "[]"
    end
  end

  describe "edited_files_live/1" do
    test "renders observed live edit paths as chips" do
      html = render_component(&Components.edited_files_live/1, paths: ["lib/harness/dashboard/live.ex"])

      assert html =~ "Files being edited"
      assert html =~ "lib/harness/dashboard/"
      assert html =~ "live.ex"
    end
  end

  describe "run_diff_view/1" do
    test "renders a populated diff with file statuses, totals, lines, and truncation note" do
      diff = %{
        added: 5,
        deleted: 2,
        branch: "harness/run-1",
        truncated: true,
        files: [
          diff_file(:added, "lib/new.ex", 3, 0, [line(:add, "+new")]),
          diff_file(:modified, "lib/edit.ex", 2, 1, [line(:meta, "index 1..2"), line(:context, "same")]),
          diff_file(:deleted, "lib/old.ex", 0, 1, [line(:del, "-old")]),
          %{diff_file(:renamed, "priv/static/logo.png", 0, 0, []) | binary: true}
        ]
      }

      html = render_component(&Components.run_diff_view/1, diff: {:ok, diff})

      assert html =~ "Changed files"
      assert html =~ "+5"
      assert html =~ "−2"
      assert html =~ "A"
      assert html =~ "M"
      assert html =~ "D"
      assert html =~ "R"
      assert html =~ "binary"
      assert html =~ "same"
      refute html =~ "index 1..2"
      assert html =~ "Diff truncated"
      assert html =~ "harness/run-1"
    end

    test "renders empty and unavailable diff states" do
      empty = %{added: 0, deleted: 0, branch: "harness/empty", truncated: false, files: []}

      assert render_component(&Components.run_diff_view/1, diff: {:ok, empty}) =~
               "No file changes recorded"

      assert render_component(&Components.run_diff_view/1, diff: {:error, :branch_absent}) =~
               "run branch was merged or cleaned up"

      assert render_component(&Components.run_diff_view/1, diff: {:error, :git_failed}) =~
               "No diff available"

      assert render_component(&Components.run_diff_view/1, diff: nil) =~
               ~s(class="changed-files")
    end
  end

  describe "config_inspector/1" do
    test "renders sections, rows, provenance pills, and env knobs" do
      sections = [
        %{
          title: "Run timeouts",
          rows: [
            %{label: "idle_timeout", value: "5 min", env_var: "HARNESS_IDLE_TIMEOUT", provenance: :env},
            %{label: "total_timeout", value: "", env_var: nil, provenance: :default}
          ]
        },
        %{
          title: "Dashboard",
          rows: [%{label: "port", value: "4018", env_var: nil, provenance: :config}]
        }
      ]

      html = render_component(&Components.config_inspector/1, sections: sections)

      assert html =~ "Configuration"
      assert html =~ "Run timeouts"
      assert html =~ "idle_timeout"
      assert html =~ "HARNESS_IDLE_TIMEOUT"
      assert html =~ ~s(data-prov="env")
      assert html =~ ~s(data-prov="default")
      assert html =~ ~s(data-prov="config")
    end
  end

  describe "config_form/1" do
    test "renders editable config rows with restart pills and input metadata" do
      entries = [
        %{
          id: "run__lifetime_timeout",
          label: "lifetime_timeout",
          unit: "ms",
          input_value: "90000",
          placeholder: "unbounded",
          restart_required?: false
        },
        %{
          id: "dashboard__port",
          label: "dashboard port",
          unit: "",
          input_value: "4018",
          placeholder: "4018",
          restart_required?: true
        }
      ]

      html = render_component(&Components.config_form/1, entries: entries)

      assert html =~ "Run &amp; dashboard config"
      assert html =~ ~s(id="config-form-run__lifetime_timeout")
      assert html =~ ~s(name="value")
      assert html =~ ~s(value="90000")
      assert html =~ ~s(placeholder="unbounded")
      assert html =~ "restart"
    end
  end

  describe "landing_card/1" do
    test "renders project landing forms and the empty state" do
      projects = [
        %{name: "manual-proj", label: "manual-proj", auto?: false, target_branch: nil},
        %{name: "auto-proj", label: "auto-proj", auto?: true, target_branch: "development"}
      ]

      html = render_component(&Components.landing_card/1, projects: projects)

      assert html =~ "Landing"
      assert html =~ ~s(id="landing-form-manual-proj")
      assert html =~ ~s(value="manual")
      assert html =~ ~s(id="landing-form-auto-proj")
      assert html =~ "auto-land"
      assert html =~ ~s(value="development")

      assert render_component(&Components.landing_card/1, projects: []) =~ "No projects registered."
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

  defp diff_file(status, path, added, deleted, lines) do
    %{status: status, path: path, added: added, deleted: deleted, binary: false, lines: lines}
  end

  defp line(kind, text), do: %{kind: kind, text: text}
end
