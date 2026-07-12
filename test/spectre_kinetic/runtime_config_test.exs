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
end
