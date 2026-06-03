defmodule Mut.OpaquePolicyTest do
  use ExUnit.Case, async: true

  alias Mut.EnvSnapshot
  alias Mut.OpaquePolicy

  describe "known_special_form?/1" do
    test "declarations are recognised" do
      for name <-
            ~w(defmodule def defp defmacro defmacrop defguard defguardp alias require import @)a do
        assert OpaquePolicy.known_special_form?(name), "expected #{name} to be known"
      end
    end

    test "function control flow is recognised" do
      for name <- ~w(case cond with for receive try fn)a do
        assert OpaquePolicy.known_special_form?(name)
      end
    end

    test "operators are recognised" do
      for name <- [:=, :when, :^, :&] do
        assert OpaquePolicy.known_special_form?(name)
      end
    end

    test "quote forms are recognised" do
      for name <- ~w(quote unquote unquote_splicing)a do
        assert OpaquePolicy.known_special_form?(name)
      end
    end

    test "if and unless are NOT in the known-special-form set" do
      refute OpaquePolicy.known_special_form?(:if)
      refute OpaquePolicy.known_special_form?(:unless)
    end

    test "arbitrary user macros are NOT special forms" do
      refute OpaquePolicy.known_special_form?(:schema)
      refute OpaquePolicy.known_special_form?(:field)
      refute OpaquePolicy.known_special_form?(:plug)
      refute OpaquePolicy.known_special_form?(:use)
    end
  end

  describe "kernel_control_flow?/1" do
    test "if and unless return true" do
      assert OpaquePolicy.kernel_control_flow?(:if)
      assert OpaquePolicy.kernel_control_flow?(:unless)
    end

    test "case and cond return false (handled by known_special_form?)" do
      refute OpaquePolicy.kernel_control_flow?(:case)
      refute OpaquePolicy.kernel_control_flow?(:cond)
    end
  end

  describe "quote_form?/1" do
    test "quote / unquote / unquote_splicing are quote forms" do
      assert OpaquePolicy.quote_form?(:quote)
      assert OpaquePolicy.quote_form?(:unquote)
      assert OpaquePolicy.quote_form?(:unquote_splicing)
    end

    test "non-quote forms return false" do
      refute OpaquePolicy.quote_form?(:case)
      refute OpaquePolicy.quote_form?(:if)
    end
  end

  defp snap(overrides) do
    struct(%EnvSnapshot{file: "lib/foo.ex", scope: :function_body, context: nil}, overrides)
  end

  describe "trusted_kernel_control_flow?/3" do
    test "returns false outside function_body scope" do
      idx = %{
        {"lib/foo.ex", 10, 5, :if, 2} => %{
          kind: :imported_macro,
          resolved_module: Kernel,
          resolved_name: :if,
          resolved_arity: 2
        }
      }

      refute OpaquePolicy.trusted_kernel_control_flow?(
               {:if, [line: 10, column: 5], [true, [do: 1, else: 2]]},
               idx,
               snap(scope: :module_body)
             )
    end

    test "returns false in match context" do
      idx = %{
        {"lib/foo.ex", 10, 5, :if, 2} => %{
          kind: :imported_macro,
          resolved_module: Kernel,
          resolved_name: :if,
          resolved_arity: 2
        }
      }

      refute OpaquePolicy.trusted_kernel_control_flow?(
               {:if, [line: 10, column: 5], [true, [do: 1]]},
               idx,
               snap(context: :match)
             )
    end

    test "returns false when tracer index is empty (no proof)" do
      refute OpaquePolicy.trusted_kernel_control_flow?(
               {:if, [line: 10, column: 5], [true, [do: 1]]},
               %{},
               snap([])
             )
    end

    test "returns false when tracer index is nil" do
      refute OpaquePolicy.trusted_kernel_control_flow?(
               {:if, [line: 10, column: 5], [true, [do: 1]]},
               nil,
               snap([])
             )
    end

    test "returns true with matching Kernel.if/2 imported_macro proof" do
      idx = %{
        {"lib/foo.ex", 10, 5, :if, 2} => %{
          kind: :imported_macro,
          resolved_module: Kernel,
          resolved_name: :if,
          resolved_arity: 2
        }
      }

      assert OpaquePolicy.trusted_kernel_control_flow?(
               {:if, [line: 10, column: 5], [true, [do: 1, else: 2]]},
               idx,
               snap([])
             )
    end

    test "returns true with matching Kernel.unless/2 remote_macro proof" do
      idx = %{
        {"lib/foo.ex", 20, 1, :unless, 2} => %{
          kind: :remote_macro,
          resolved_module: Kernel,
          resolved_name: :unless,
          resolved_arity: 2
        }
      }

      assert OpaquePolicy.trusted_kernel_control_flow?(
               {:unless, [line: 20, column: 1], [false, [do: 1]]},
               idx,
               snap([])
             )
    end

    test "returns false when the proof resolves to a user module, not Kernel" do
      idx = %{
        {"lib/foo.ex", 10, 5, :if, 2} => %{
          kind: :imported_macro,
          resolved_module: MyApp.Conditional,
          resolved_name: :if,
          resolved_arity: 2
        }
      }

      refute OpaquePolicy.trusted_kernel_control_flow?(
               {:if, [line: 10, column: 5], [true, [do: 1]]},
               idx,
               snap([])
             )
    end

    test "returns false for non-control-flow names" do
      idx = %{
        {"lib/foo.ex", 10, 5, :case, 2} => %{
          kind: :imported_macro,
          resolved_module: Kernel,
          resolved_name: :case,
          resolved_arity: 2
        }
      }

      refute OpaquePolicy.trusted_kernel_control_flow?(
               {:case, [line: 10, column: 5], [1, [do: []]]},
               idx,
               snap([])
             )
    end
  end

  describe "kernel_control_flow_proven?/3 (Tier-3 syntactic gate, no EnvSnapshot)" do
    defp kernel_if_index(file \\ "lib/foo.ex") do
      %{
        {file, 10, 5, :if, 2} => %{
          kind: :imported_macro,
          resolved_module: Kernel,
          resolved_name: :if,
          resolved_arity: 2
        }
      }
    end

    test "true with matching Kernel.if/2 proof for the candidate's file" do
      assert OpaquePolicy.kernel_control_flow_proven?(
               {:if, [line: 10, column: 5], [true, [do: 1, else: 2]]},
               kernel_if_index(),
               "lib/foo.ex"
             )
    end

    test "false when the proof resolves to a user module (shadowed if)" do
      idx = put_in(kernel_if_index()[{"lib/foo.ex", 10, 5, :if, 2}].resolved_module, MyApp.DSL)

      refute OpaquePolicy.kernel_control_flow_proven?(
               {:if, [line: 10, column: 5], [true, [do: 1]]},
               idx,
               "lib/foo.ex"
             )
    end

    test "false on nil / empty index, non-if/unless node, and unmatched position" do
      node = {:if, [line: 10, column: 5], [true, [do: 1]]}
      refute OpaquePolicy.kernel_control_flow_proven?(node, nil, "lib/foo.ex")
      refute OpaquePolicy.kernel_control_flow_proven?(node, %{}, "lib/foo.ex")

      refute OpaquePolicy.kernel_control_flow_proven?(
               {:case, [line: 10, column: 5], [1, [do: []]]},
               kernel_if_index(),
               "lib/foo.ex"
             )

      # Right node, wrong file/line -> no matching tracer event -> unproven.
      refute OpaquePolicy.kernel_control_flow_proven?(node, kernel_if_index(), "lib/other.ex")

      refute OpaquePolicy.kernel_control_flow_proven?(
               {:if, [line: 99, column: 5], [true, [do: 1]]},
               kernel_if_index(),
               "lib/foo.ex"
             )
    end
  end

  describe "opaque_call_trust_level/0" do
    test "always :opaque" do
      assert OpaquePolicy.opaque_call_trust_level() == :opaque
    end
  end
end
