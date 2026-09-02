defmodule Mut.OrchestratorIdentityMutationTest do
  use ExUnit.Case, async: false

  @moduledoc "T06: mutants whose rendered text equals the original are rejected."

  alias Mut.FixtureOracleHelper
  alias Mut.Mutation

  @fixture_root Path.expand("test/fixtures/orchestrator_identity")

  # A mutator that "mutates" a float literal to a node which renders back to
  # the original source bytes: `Macro.to_string/1` honours the `:token`
  # metadata, so `{:__block__, [token: "3.14"], [0.0]}` renders as `3.14`.
  defmodule IdentityFloat do
    @moduledoc false
    @behaviour Mut.Mutator

    @impl true
    def name, do: "IdentityFloat"

    @impl true
    def description, do: "Identity float replacement (test double)."

    @impl true
    def targets, do: [:body_literal]

    @impl true
    def applicable?({:__block__, _meta, [value]}, %Mut.Context{}) when is_float(value), do: true
    def applicable?(_node, %Mut.Context{}), do: false

    @impl true
    def mutate({:__block__, meta, [value]} = node, %Mut.Context{} = ctx) do
      if applicable?(node, ctx) do
        meta = if Process.get(:identity_float_keep_token, true), do: meta, else: []

        [
          %Mutation{
            original_ast: node,
            mutated_ast: {:__block__, meta, [0.0]},
            description: "replace float literal with 0.0",
            mutation_kind: :float_literal,
            guard_safe?: false,
            metadata: %{from: value, to: 0.0}
          }
        ]
      else
        []
      end
    end

    @impl true
    def equivalent?(%Mutation{metadata: %{from: from, to: to}}), do: from == to
    def equivalent?(_mutation), do: false
  end

  setup_all do
    path = Path.join(@fixture_root, "lib/floaty.ex")
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    defmodule Floaty do
      @moduledoc false

      def pi, do: 3.14
    end
    """)

    :ok
  end

  defp oracle, do: FixtureOracleHelper.oracle([])

  defp plan do
    Mut.Orchestrator.plan(@fixture_root, oracle(),
      files: ["lib/floaty.ex"],
      enabled_targets: [:body_literal],
      mutators: [IdentityFloat]
    )
  end

  test "the literal really does render back to the original bytes" do
    assert Macro.to_string({:__block__, [token: "3.14"], [0.0]}) == "3.14"
  end

  test "an identity mutant is not executable and is recorded as a skip" do
    plan = plan()

    assert plan.schema == []
    assert plan.fallback == []

    assert Enum.any?(plan.skipped, &(&1.reason == :identity_mutation)),
           "expected the byte-identical mutant to be skipped, got: #{inspect(plan.skipped)}"

    skip = Enum.find(plan.skipped, &(&1.reason == :identity_mutation))
    assert skip.file == "lib/floaty.ex"
    assert skip.syntactic_name == :float_literal
  end

  test "a non-identity mutant on the same literal survives the check" do
    Process.put(:identity_float_keep_token, false)
    plan = plan()

    mutants = plan.schema ++ plan.fallback
    assert [%Mut.Mutant{mutation_kind: :float_literal}] = mutants
    refute Enum.any?(plan.skipped, &(&1.reason == :identity_mutation))
  end
end
