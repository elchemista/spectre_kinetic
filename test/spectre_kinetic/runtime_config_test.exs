defmodule SpectreKinetic.RuntimeConfigTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.RuntimeConfig

  describe "normalize_request/1" do
    test "treats nil atom keys as absent and keeps false slot values" do
      request = %{
        :al => nil,
        "al" => "SEND MESSAGE WITH: FORCE=false",
        slots: %{force: false, optional: nil}
      }

      normalized = RuntimeConfig.normalize_request(request)

      assert normalized["al"] == "SEND MESSAGE WITH: FORCE=false"
      assert normalized["slots"] == %{"force" => false, "optional" => nil}
    end

    test "normalizes and preserves fallback request overrides" do
      normalized =
        RuntimeConfig.normalize_request(%{
          "al" => "SEND MESSAGE",
          "tool_selection_fallback" => "RERANKER",
          "fallback_top_k" => 2,
          "fallback_margin" => 0.2,
          "reranker_threshold" => 0.7
        })

      assert normalized["tool_selection_fallback"] == :reranker
      assert normalized["fallback_top_k"] == 2
      assert normalized["fallback_margin"] == 0.2
      assert normalized["reranker_threshold"] == 0.7
    end
  end

  describe "public input validation" do
    test "returns field-level errors for malformed requests" do
      assert {:error, {:invalid_request, issues}} =
               RuntimeConfig.validate_request(%{
                 "al" => 123,
                 "slots" => [],
                 "top_k" => 0,
                 "tool_threshold" => 1.1,
                 "mapping_threshold" => -0.1,
                 "tool_selection_fallback" => "magic",
                 "fallback_top_k" => 0,
                 "fallback_margin" => "close",
                 "reranker_threshold" => 2.0
               })

      assert Enum.map(issues, & &1.field) == [
               :al,
               :slots,
               :top_k,
               :tool_threshold,
               :mapping_threshold,
               :tool_selection_fallback,
               :fallback_top_k,
               :fallback_margin,
               :reranker_threshold
             ]

      assert Enum.all?(issues, &(Map.keys(&1) |> Enum.sort() == [:field, :reason]))
    end

    test "rejects invalid option containers and slot values" do
      assert {:error,
              {:invalid_options,
               [%{field: :options, reason: :must_be_keyword_or_atom_keyed_map}]}} =
               RuntimeConfig.validate_options([:not_a_keyword])

      assert {:error,
              {:invalid_options, [%{field: :options, reason: :must_have_unique_keys}]}} =
               RuntimeConfig.validate_options(top_k: 5, top_k: 0)

      assert {:error,
              {:invalid_options,
               [%{field: :slots, reason: :must_be_json_compatible_map}]}} =
               RuntimeConfig.validate_options(slots: %{callback: fn -> :ok end})

      assert {:error,
              {:invalid_options,
               [%{field: :slots, reason: :must_be_json_compatible_map}]}} =
               RuntimeConfig.validate_options(slots: %{items: [1 | :improper]})
    end

    test "accepts bounded options and JSON-compatible nested slots" do
      assert :ok =
               RuntimeConfig.validate_plan_input(
                 "SEND MESSAGE WITH: ID=42",
                 slots: %{id: 42, metadata: %{"tags" => ["urgent"], "enabled" => true}},
                 top_k: 1,
                 tool_threshold: 0.0,
                 mapping_threshold: 1.0,
                 fallback_top_k: 2,
                 fallback_margin: 0.25,
                 reranker_threshold: 0.75,
                 tool_selection_fallback: :reranker
               )
    end
  end
end
