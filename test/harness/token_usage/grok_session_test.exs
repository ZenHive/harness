defmodule Harness.TokenUsage.GrokSessionTest do
  use ExUnit.Case, async: false

  alias Harness.TokenUsage
  alias Harness.TokenUsage.GrokSession

  @session_id "019e824d-9b97-7c82-bdbe-9e5784c6cd6b"

  setup do
    root = Path.join(System.tmp_dir!(), "grok-sessions-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:harness, :grok_sessions_root)
    Application.put_env(:harness, :grok_sessions_root, root)

    on_exit(fn ->
      File.rm_rf!(root)

      if prev,
        do: Application.put_env(:harness, :grok_sessions_root, prev),
        else: Application.delete_env(:harness, :grok_sessions_root)
    end)

    {:ok, root: root}
  end

  # Writes an `updates.jsonl` under a percent-encoded cwd dir, mirroring grok's
  # real on-disk layout, and returns the matching captured-stdout transcript.
  @spec seed(binary(), [non_neg_integer()], binary()) :: binary()
  defp seed(root, totals, session_id \\ @session_id) do
    encoded = "%2FUsers%2Fefries%2F_DATA%2Fworktrees%2F.harness%2Fharness%2Frun-1-a"
    dir = Path.join([root, encoded, session_id])
    File.mkdir_p!(dir)

    lines =
      Enum.map_join(totals, "\n", fn t ->
        ~s({"method":"session/update","params":{"_meta":{"totalTokens":#{t},"updateType":"ToolCallUpdate"}}})
      end)

    File.write!(Path.join(dir, "updates.jsonl"), lines)

    ~s({"type":"text","data":"done"}\n) <>
      ~s({"type":"end","stopReason":"EndTurn","sessionId":"#{session_id}","requestId":"r1"}\n)
  end

  describe "usage/1" do
    test "recovers the max cumulative totalTokens as :total", %{root: root} do
      transcript = seed(root, [5380, 27_735, 123_904, 28_825])

      assert %TokenUsage{total: 123_904, input: nil, output: nil} = GrokSession.usage(transcript)
      assert TokenUsage.measured?(GrokSession.usage(transcript))
    end

    test "returns empty when the transcript carries no end-event session id", %{root: root} do
      seed(root, [42])
      transcript = ~s({"type":"text","data":"no end event here"}\n)

      assert GrokSession.usage(transcript) == TokenUsage.empty()
    end

    test "returns empty when the session log is absent (no file for that id)", %{root: _root} do
      transcript =
        ~s({"type":"end","stopReason":"EndTurn","sessionId":"deadbeef-0000-0000-0000-000000000000"}\n)

      assert GrokSession.usage(transcript) == TokenUsage.empty()
    end

    test "returns empty when the log has no totalTokens", %{root: root} do
      encoded = "cwd"
      dir = Path.join([root, encoded, @session_id])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "updates.jsonl"), ~s({"method":"session/update","params":{}}))

      transcript = ~s({"type":"end","sessionId":"#{@session_id}"}\n)
      assert GrokSession.usage(transcript) == TokenUsage.empty()
    end

    test "rejects a traversal payload in the session id", %{root: root} do
      seed(root, [99])
      # An id with path separators must never reach File.read.
      transcript = ~s({"type":"end","sessionId":"../../etc/passwd"}\n)

      assert GrokSession.usage(transcript) == TokenUsage.empty()
    end

    test "non-binary input yields empty" do
      assert GrokSession.usage(nil) == TokenUsage.empty()
      assert GrokSession.usage(%{}) == TokenUsage.empty()
    end
  end
end
