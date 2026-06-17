defmodule Harness.Dashboard.ComponentsTest do
  # Unit tests for the shared dashboard chrome components (Task 85). Full page
  # render is browser-verified per Task 50/85; the structural pieces — bucket
  # glyph/label mapping and the persistent navbar/footer markup — are covered
  # here as direct `render_component` calls.

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Harness.Dashboard.Components
  alias Harness.Dashboard.Transcript.Parser
  alias Harness.Run.Status

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
      assert html =~ ~s(href="/harness/roadmap")
      assert html =~ ~s(href="/harness/chat")
      assert html =~ ~s(href="/harness/oban")
    end

    test "links to the project-structure explorer (Task 305)" do
      html = render_component(&Components.navbar/1, %{})
      assert html =~ ~s(href="/harness/projects/explore")
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

  describe "run_timing/1" do
    test "renders elapsed, current-stage time, and per-stage durations" do
      started_at = ~U[2026-06-17 08:00:00.000Z]
      running_at = DateTime.add(started_at, 2, :second)
      committing_at = DateTime.add(started_at, 7, :second)
      reviewing_at = DateTime.add(started_at, 9, :second)
      now = DateTime.add(started_at, 12, :second)

      status = %Status{
        run_id: "run-timed",
        task_id: "313",
        state: :reviewing,
        started_at: started_at,
        state_entered_at: %{
          dispatched: started_at,
          running: running_at,
          committing: committing_at,
          reviewing: reviewing_at
        }
      }

      html = render_component(&Components.run_timing/1, status: status, now: now)

      assert html =~ ~s(data-run-elapsed)
      assert html =~ ">12s<"
      assert html =~ "Reviewing · 3s"
      assert html =~ "Dispatched: 2s"
      assert html =~ "Running: 5s"
      assert html =~ "Committing: 2s"
      assert html =~ "Reviewing: 3s"
    end

    test "freezes final elapsed at the terminal state entry" do
      started_at = ~U[2026-06-17 08:00:00.000Z]
      done_at = DateTime.add(started_at, 10, :second)
      now = DateTime.add(started_at, 60, :second)

      status = %Status{
        run_id: "run-done",
        task_id: "313",
        state: :done,
        started_at: started_at,
        state_entered_at: %{dispatched: started_at, done: done_at}
      }

      html = render_component(&Components.run_timing/1, status: status, now: now)

      assert html =~ ">10s<"
      refute html =~ ">1m 0s<"
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

    test "renders blocks newest-first (latest turn on top)" do
      events = [
        {:assistant_text, %{text: "oldest turn"}},
        {:system, %{kind: :result, data: %{"status" => "ok"}}},
        {:assistant_text, %{text: "newest turn"}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :claude)

      # The latest turn's text precedes the oldest turn's text in the rendered DOM.
      assert :binary.match(html, "newest turn") < :binary.match(html, "oldest turn")
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

    test "coalesces consecutive other and unknown events into one legible system row" do
      events = [
        {:system, %{kind: :other, data: %{"_type" => "message_delta", "text" => "alpha"}}},
        {:system, %{kind: :other, data: %{"_type" => "tool_call_delta", "delta" => "beta"}}},
        {:unknown, %{raw: ~s({"type":"broken","text":"gamma")}},
        {:system, %{kind: :other, data: %{"_type" => "message_delta", "text" => "delta"}}}
      ]

      html = render_component(&Components.transcript_view/1, events: events, agent: :cursor)

      assert html |> String.split(~s(class="eyebrow")) |> length() == 2
      assert html =~ "4 events"
      assert html =~ "message_delta"
      assert html =~ "tool_call_delta"
      assert html =~ "unknown"
      assert html =~ "gamma"
    end

    test "cursor parser output round-trips through transcript_view with tool details intact" do
      transcript = """
      {"type":"tool_call","subtype":"started","call_id":"tool_read","tool_call":{"readToolCall":{"args":{"path":"/repo/mix.exs","limit":30}},"hookAdditionalContexts":[],"toolCallId":"tool_read"}}
      {"type":"tool_call","subtype":"completed","call_id":"tool_read","tool_call":{"readToolCall":{"args":{"path":"/repo/mix.exs","limit":30},"result":{"success":{"content":"app: :harness"}}},"hookAdditionalContexts":[],"toolCallId":"tool_read"}}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"h"}]},"timestamp_ms":1781650952975}
      {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"arness"}]},"timestamp_ms":1781650952976}
      {"type":"connection","subtype":"reconnecting","session_id":"s","timestamp_ms":1781650953000}
      """

      events = Parser.replay(:cursor, transcript)
      html = render_component(&Components.transcript_view/1, events: events, agent: :cursor)

      assert html =~ ">read</span>"
      assert html =~ "/repo/mix.exs"
      assert html =~ "app: :harness"
      assert html =~ "harness"
      assert html =~ "connection"
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
    test "renders observed live edit paths as chips with +/- or edit counts" do
      files = [
        %{path: "lib/harness/dashboard/live.ex", added: 3, deleted: 1, edits: 2},
        %{path: "lib/other.ex", added: 0, deleted: 0, edits: 1}
      ]

      html = render_component(&Components.edited_files_live/1, files: files)

      assert html =~ "Files being edited"
      assert html =~ "lib/harness/dashboard/"
      assert html =~ "live.ex"
      assert html =~ "+3"
      assert html =~ "−1"
      assert html =~ "1 edits"
    end
  end

  describe "transcript chrome (Task 314)" do
    test "transcript_chrome renders summary, activity, and heartbeat" do
      events = [
        {:assistant_tool_use, %{id: "1", name: "Edit", input: %{"file_path" => "lib/a.ex", "old_string" => "x", "new_string" => "y"}}}
      ]

      last_at = ~U[2026-06-17 10:00:05.000Z]
      now = ~U[2026-06-17 10:00:10.000Z]

      html =
        render_component(&Components.transcript_chrome/1,
          events: events,
          agent: :claude,
          last_event_at: last_at,
          now: now,
          live: true
        )

      assert html =~ ~s(data-transcript-summary)
      assert html =~ "1 turns · 1 tool calls · 1 files"
      assert html =~ "editing lib/a.ex"
      assert html =~ "5s ago"
      assert html =~ "last output"
    end

    test "counts turns, tool calls, and files from the event list" do
      events = [
        {:assistant_text, %{text: "hi"}},
        {:assistant_tool_use, %{id: "1", name: "Edit", input: %{"file_path" => "a.ex", "new_string" => "line1\nline2"}}},
        {:assistant_tool_use, %{id: "2", name: "Read", input: %{"path" => "b.ex"}}}
      ]

      assert Components.transcript_counts(events, :claude) == %{turns: 1, tool_calls: 2, files: 2}
      assert Components.current_activity_label(events) == "Read b.ex"
    end

    test "last_output_age_label reports mechanical seconds since last event" do
      last_at = ~U[2026-06-17 10:00:00.000Z]

      assert Components.last_output_age_label(last_at, DateTime.add(last_at, 3, :second)) == "3s ago"
      assert Components.last_output_age_label(last_at, last_at) == "<1s ago"
      assert Components.last_output_age_label(nil, last_at) == nil
    end

    test "edited_file_stats accumulates per-file line deltas and edit counts" do
      events = [
        {:assistant_tool_use,
         %{
           id: "1",
           name: "Edit",
           input: %{"file_path" => "lib/a.ex", "old_string" => "old", "new_string" => "new1\nnew2"}
         }},
        {:assistant_tool_use, %{id: "2", name: "Read", input: %{"path" => "lib/b.ex"}}}
      ]

      [a, b] = Components.edited_file_stats(events)

      assert a.path == "lib/a.ex"
      assert a.added == 2
      assert a.deleted == 1
      assert a.edits == 1
      assert b.path == "lib/b.ex"
      assert b.edits == 1
      assert b.added == 0
      assert b.deleted == 0
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

  describe "project_settings_card/1" do
    test "renders concurrency, edit, register, and remove controls" do
      projects = [
        %{
          name: "demo",
          label: "demo",
          source_type: "local",
          source_location: "/tmp/demo",
          roadmap_path: "/tmp/demo",
          check_command: "mix precommit",
          target_branch: "development",
          concurrency_cap: "2",
          concurrency_label: "2",
          warm_paths: "priv/discoveries\nsource"
        }
      ]

      html = render_component(&Components.project_settings_card/1, projects: projects)

      assert html =~ ~s(id="concurrency-form-demo")
      assert html =~ ~s(id="project-form-demo")
      assert html =~ ~s(id="project-form-new")
      assert html =~ ~s(name="warm_paths")
      assert html =~ "priv/discoveries"
      assert html =~ ~s(id="unregister-project-demo")
    end
  end

  describe "stage_stepper/1 (Task 312)" do
    test "renders the base pipeline with the current stage emphasized" do
      html = render_component(&Components.stage_stepper/1, state: :reviewing)

      assert html =~ ~s(data-run-stage-stepper)
      assert html =~ ~s(data-stage="reviewing" data-status="current")
      assert html =~ ~s(data-stage="committing" data-status="complete")
      assert html =~ ~s(data-stage="running" data-status="complete")
      assert html =~ ~s(data-stage="dispatched" data-status="complete")
    end

    test "inserts recovering only while the run is recovering" do
      html = render_component(&Components.stage_stepper/1, state: :recovering)

      assert html =~ ~s(data-stage="recovering" data-status="current")
      refute html =~ ~s(data-stage="held")
    end

    test "inserts held only while the run is held" do
      html = render_component(&Components.stage_stepper/1, state: :held)

      assert html =~ ~s(data-stage="held" data-status="current")
      refute html =~ ~s(data-stage="recovering")
    end

    test "terminal done marks the full pipeline complete through Done" do
      html = render_component(&Components.stage_stepper/1, state: :done)

      assert html =~ ~s(data-stage="done" data-status="current")
      assert html =~ ~s(data-stage="reviewing" data-status="complete")
    end

    test "stage_stepper_steps/1 maps each in-flight state to the right current step" do
      for {state, current} <- [
            dispatched: :dispatched,
            running: :running,
            committing: :committing,
            reviewing: :reviewing,
            recovering: :recovering,
            held: :held
          ] do
        steps = Components.stage_stepper_steps(state)
        current_step = Enum.find(steps, &(&1.status == :current))
        assert current_step.stage == current, "expected #{state} to emphasize #{current}"
      end
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
