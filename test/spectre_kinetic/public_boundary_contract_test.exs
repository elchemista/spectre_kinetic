defmodule SpectreKinetic.PublicBoundaryContractTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Action
  alias SpectreKinetic.ActionChain

  setup do
    runtime = SpectreKinetic.load_runtime!(allow_empty_registry: true)
    on_exit(fn -> SpectreKinetic.close_runtime(runtime) end)
    %{runtime: runtime}
  end

  test "chain planning accepts proper bounded lists and preserves one result per step", %{
    runtime: runtime
  } do
    assert {:ok, %ActionChain{actions: []}} = SpectreKinetic.plan_chain(runtime, [])

    assert {:ok, %ActionChain{actions: actions}} =
             SpectreKinetic.plan_chain(
               runtime,
               ["SEND EMAIL", "DELETE MESSAGE"],
               %{tool_threshold: 0.0}
             )

    assert [
             %Action{index: 0, status: :no_tool, al: "SEND EMAIL"},
             %Action{index: 1, status: :no_tool, al: "DELETE MESSAGE"}
           ] = actions
  end

  test "chain planning rejects hostile scalar, encoding, size, and list shapes", %{
    runtime: runtime
  } do
    assert_chain_error(SpectreKinetic.plan_chain(runtime, :not_text), :must_be_binary_or_list)
    assert_chain_error(SpectreKinetic.plan_chain(runtime, <<255>>), :must_be_utf8_binary)

    assert_chain_error(
      SpectreKinetic.plan_chain(runtime, String.duplicate("x", 1_048_577)),
      :exceeds_size_limit
    )

    assert_chain_error(
      SpectreKinetic.plan_chain(runtime, [<<255>>]),
      :must_contain_utf8_binaries
    )

    assert_chain_error(
      SpectreKinetic.plan_chain(runtime, [:not_text]),
      :must_contain_utf8_binaries
    )

    assert_chain_error(
      SpectreKinetic.plan_chain(runtime, ["SEND EMAIL" | :improper]),
      :must_be_proper_list
    )

    assert_chain_error(
      SpectreKinetic.plan_chain(runtime, [String.duplicate("x", 32_769)]),
      :exceeds_size_limit
    )

    assert_chain_error(
      SpectreKinetic.plan_chain(runtime, List.duplicate("SEND EMAIL", 129)),
      :too_many_steps
    )
  end

  test "extracted model output is also capped before any action is planned", %{runtime: runtime} do
    response = Enum.map_join(1..129, "\n", &"AL: SEND EMAIL #{&1}")

    assert_chain_error(SpectreKinetic.plan_chain(runtime, response), :too_many_steps)
  end

  test "JSON request planning uses the same closed request schema", %{runtime: runtime} do
    assert {:error, {:invalid_request, errors}} =
             SpectreKinetic.plan_json(runtime, Jason.encode!(%{"unexpected" => true}))

    assert Enum.any?(errors, &(&1.field == :al))
  end

  test "tool annotations reject private and non-string declarations at compile time" do
    private_module = unique_module("PrivateAnnotation")
    invalid_module = unique_module("InvalidAnnotation")

    assert_raise ArgumentError, ~r/@al can only annotate public functions/, fn ->
      Code.compile_string("""
      defmodule #{inspect(private_module)} do
        use SpectreKinetic
        @al "DO PRIVATE WORK"
        defp hidden(value), do: value
      end
      """)
    end

    assert_raise ArgumentError, ~r/@al must be a string/, fn ->
      Code.compile_string("""
      defmodule #{inspect(invalid_module)} do
        use SpectreKinetic
        @al 42
        def run(value), do: value
      end
      """)
    end
  end

  test "tool metadata names defaults but never invents names for patterns" do
    module = unique_module("ToolParameters")

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use SpectreKinetic

      @al "RUN TOOL"
      def run(value \\\\ "default", %{key: key}), do: {value, key}
    end
    """)

    assert [
             %{
               function: :run,
               arity: 2,
               params: ["value", "arg2"],
               al: "RUN TOOL"
             }
           ] = module.__spectre_tools__()
  end

  defp assert_chain_error(result, reason) do
    assert result == {:error, {:invalid_request, [%{field: :chain, reason: reason}]}}
  end

  defp unique_module(suffix) do
    Module.concat([
      __MODULE__,
      String.to_atom("#{suffix}#{System.unique_integer([:positive])}")
    ])
  end
end
