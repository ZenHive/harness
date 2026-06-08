defmodule Harness.Dashboard.OpsFeedTest do
  use ExUnit.Case, async: true

  alias Harness.Dashboard.OpsFeed
  alias Harness.Dashboard.OpsFeed.Op
  alias Harness.Dashboard.RunFeed

  doctest Op

  describe "topic/0" do
    test "is the stable ops topic, distinct from the run feed" do
      assert OpsFeed.topic() == "harness:ops"
      refute OpsFeed.topic() == RunFeed.topic()
    end
  end

  describe "subscribe/0 + broadcast/1" do
    test "a subscriber receives the op, stamped with an id and timestamp" do
      assert :ok = OpsFeed.subscribe()
      op = Op.audit_started("demo", "codex", "abc")

      assert :ok = OpsFeed.broadcast(op)
      assert_receive {:harness_op, %Op{kind: :audit, stage: :started, agent: "codex"} = received}
      assert is_binary(received.id)
      assert %DateTime{} = received.at
    end

    test "preserves a caller-set id rather than overwriting it" do
      :ok = OpsFeed.subscribe()
      op = %{Op.audit_started("demo", "codex", "abc") | id: "fixed-id"}

      :ok = OpsFeed.broadcast(op)
      assert_receive {:harness_op, %Op{id: "fixed-id"}}
    end

    test "caps a large audit transcript to the tail" do
      :ok = OpsFeed.subscribe()
      big = String.duplicate("x", 20_000) <> "TAIL"
      op = Op.audit_settled("demo", "codex", "r", {:audited, "deadbeef"}, big)

      :ok = OpsFeed.broadcast(op)
      assert_receive {:harness_op, %Op{transcript: transcript}}
      assert byte_size(transcript) <= 16_000
      assert String.ends_with?(transcript, "TAIL")
    end
  end

  describe "unsubscribe/0" do
    test "stops delivery after unsubscribe" do
      :ok = OpsFeed.subscribe()
      :ok = OpsFeed.unsubscribe()

      OpsFeed.broadcast(Op.audit_started("demo", "codex", "abc"))
      refute_receive {:harness_op, _}, 100
    end
  end

  describe "Op.audit_settled/5 outcome relabeling" do
    test "maps each audit outcome to its display stage" do
      assert %Op{stage: :fixed, sha: "s1"} = Op.audit_settled("p", "a", "r", {:audited, "s1"}, "out")
      assert %Op{stage: :clean} = Op.audit_settled("p", "a", "r", :no_changes, "out")
      assert %Op{stage: :noop} = Op.audit_settled("p", "a", "r", :noop, nil)
      assert %Op{stage: :push_rejected} = Op.audit_settled("p", "a", "r", {:push_rejected, "x"}, nil)
      assert %Op{stage: :skipped, detail: detail} = Op.audit_settled("p", nil, "r", {:skipped, :no_audit_agent}, nil)
      assert detail =~ "no_audit_agent"
      assert %Op{stage: :error} = Op.audit_settled("p", "a", "r", {:error, :boom}, nil)
    end
  end

  describe "Op.land_* outcome relabeling" do
    defp request, do: %{project: %{name: "demo", target_branch: "main"}, run_id: "r1"}

    test "land_started/1 carries project, run, and target from the request" do
      assert %Op{kind: :land, stage: :landing, project: "demo", run_id: "r1", target: "main"} =
               Op.land_started(request())
    end

    test "land_stage/2 stamps a non-terminal substage" do
      assert %Op{kind: :land, stage: :resolving, run_id: "r1"} = Op.land_stage(request(), :resolving)
    end

    test "land_settled/2 maps each land outcome to its display stage" do
      assert %Op{stage: :landed, sha: "cafe"} = Op.land_settled(request(), {:landed, "cafe"})
      assert %Op{stage: :conflict} = Op.land_settled(request(), {:conflict, "CONFLICT"})
      assert %Op{stage: :push_rejected} = Op.land_settled(request(), {:push_rejected, "x"})
      assert %Op{stage: :skipped} = Op.land_settled(request(), {:skipped, {:github, "url"}})
      assert %Op{stage: :error} = Op.land_settled(request(), {:error, :boom})
    end

    test "blocked/2 builds from string-keyed Oban args" do
      args = %{"project_name" => "demo", "run_id" => "r1", "task_id" => "1"}

      assert %Op{kind: :land, stage: :blocked, project: "demo", run_id: "r1", detail: "cap exhausted"} =
               Op.blocked(args, "cap exhausted")
    end
  end
end
