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
  end
end
