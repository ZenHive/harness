defmodule Harness.ResultStore.DeadLetterTest do
  @moduledoc """
  Unit tests for the durable settle-time run-record spill (Task 370).
  """
  use ExUnit.Case, async: false

  alias Harness.ResultStore.DeadLetter
  alias Harness.ResultStoreContract

  @moduletag :tmp_dir
  @lock_probe_timeout_ms 50

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "dead_letter")
    prev = Application.get_env(:harness, :result_store_dead_letter)
    Application.put_env(:harness, :result_store_dead_letter, root: root)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:harness, :result_store_dead_letter, prev),
        else: Application.delete_env(:harness, :result_store_dead_letter)
    end)

    %{root: root}
  end

  describe "spill/3 + load/1 + delete/1" do
    test "round-trips a LogRecord and pending migration labels" do
      record = ResultStoreContract.log_record(run_id: "run-spill-1", task_id: "370", verdict: :approve)

      assert {:ok, entry} =
               DeadLetter.spill(record, :simulated_undefined_column,
                 pending_migrations: [{20_260_720_120_000, "add_review_proposed_tasks_to_run_records"}]
               )

      assert entry.run_id == "run-spill-1"
      assert entry.path == DeadLetter.path_for("run-spill-1")
      assert File.exists?(entry.path)
      assert DeadLetter.exists?("run-spill-1")

      assert {:ok, loaded} = DeadLetter.load("run-spill-1")
      assert loaded.record.run_id == "run-spill-1"
      assert loaded.record.verdict == :approve
      assert loaded.pending_migrations == [{20_260_720_120_000, "add_review_proposed_tasks_to_run_records"}]
      assert loaded.reason == :simulated_undefined_column

      assert :ok = DeadLetter.delete("run-spill-1")
      assert {:error, :not_found} = DeadLetter.load("run-spill-1")
      # delete is idempotent
      assert :ok = DeadLetter.delete("run-spill-1")
    end

    test "patch_landed_sha updates a spilled record's landing witness" do
      record = ResultStoreContract.log_record(run_id: "run-spill-land", landed_sha: nil)
      assert {:ok, _} = DeadLetter.spill(record, :boom)

      assert :ok = DeadLetter.patch_landed_sha("run-spill-land", "deadbeefcafe")
      assert {:ok, %{record: %{landed_sha: "deadbeefcafe"}}} = DeadLetter.load("run-spill-land")
    end

    test "patch_landed_sha is a no-op when no spill exists" do
      assert :ok = DeadLetter.patch_landed_sha("no-such-run", "abc")
    end

    test "load restores a spill whose ETF contains an atom absent from the reading node" do
      # Unique 10-byte marker so the replace cannot collide with struct field
      # names such as `approved_then_found_red`.
      record = ResultStoreContract.log_record(run_id: "run-cold-etf", reason: :dlknownatm)
      assert {:ok, entry} = DeadLetter.spill(record, :x)

      cold = "dlcoldatom"
      assert_raise ArgumentError, fn -> String.to_existing_atom(cold) end

      bin = File.read!(entry.path)
      replaced = :binary.replace(bin, "dlknownatm", cold)
      assert_raise ArgumentError, fn -> :erlang.binary_to_term(replaced, [:safe]) end
      File.write!(entry.path, replaced)

      assert {:ok, loaded} = DeadLetter.load("run-cold-etf")
      assert loaded.record.run_id == "run-cold-etf"
      assert Atom.to_string(loaded.record.reason) == cold
    end

    test "list/0 returns every readable spill" do
      for id <- ["run-a", "run-b"] do
        assert {:ok, _} = DeadLetter.spill(ResultStoreContract.log_record(run_id: id), :x)
      end

      ids = DeadLetter.list() |> Enum.map(& &1.run_id) |> Enum.sort()
      assert ids == ["run-a", "run-b"]
    end

    test "sanitizes path separators in run_id so spills stay under root", %{root: root} do
      evil = ResultStoreContract.log_record(run_id: "../escape")
      assert {:ok, entry} = DeadLetter.spill(evil, :x)
      assert String.starts_with?(entry.path, root)
      assert Path.basename(entry.path) == "___escape.etf"
      # Resolved path must still live under root (no directory traversal).
      assert String.starts_with?(Path.expand(entry.path), Path.expand(root))
    end

    test "serializes spill operations for the same run id" do
      parent = self()

      holder =
        Task.async(fn ->
          DeadLetter.with_run_lock("run-locked", fn ->
            send(parent, :lock_held)

            receive do
              :release_lock -> :ok
            end
          end)
        end)

      assert_receive :lock_held

      waiter =
        Task.async(fn ->
          DeadLetter.with_run_lock("run-locked", fn -> send(parent, :waiter_entered) end)
        end)

      refute_receive :waiter_entered, @lock_probe_timeout_ms
      send(holder.pid, :release_lock)
      assert :ok = Task.await(holder)
      assert :waiter_entered = Task.await(waiter)
      assert_receive :waiter_entered
    end
  end
end
