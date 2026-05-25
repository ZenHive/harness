defmodule Harness.CheckStackTest do
  use ExUnit.Case, async: true

  alias Harness.CheckStack
  alias Harness.Verification.Check

  describe "%CheckStack{}" do
    test "enforces :name and :checks; defaults :parser and :timeout_per_check to nil" do
      stack = %CheckStack{name: :tiny, checks: [check("a", "true")]}
      assert stack.name == :tiny
      assert stack.checks == [%Check{name: "a", command: "true", args: []}]
      assert stack.parser == nil
      assert stack.timeout_per_check == nil
    end

    test "carries an explicit parser and timeout_per_check when given" do
      stack = %CheckStack{
        name: :custom,
        checks: [check("a", "true")],
        parser: SomeParser,
        timeout_per_check: 5_000
      }

      assert stack.parser == SomeParser
      assert stack.timeout_per_check == 5_000
    end

    test "requires :name and :checks" do
      assert_raise ArgumentError, fn -> struct!(CheckStack, name: :only) end
      assert_raise ArgumentError, fn -> struct!(CheckStack, checks: []) end
    end
  end

  defp check(name, command), do: %Check{name: name, command: command, args: []}
end
