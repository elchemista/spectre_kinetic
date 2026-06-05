defmodule SpectreKinetic.Planner.CompilerTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Compiler

  test "compile/1 rejects non-list inline actions before loading artifacts" do
    assert {:error, {:invalid_option, :actions}} =
             Compiler.compile(actions: :nope, encoder_model_dir: "unused", output: "unused.etf")
  end

  test "compile/1 still requires registry_json when inline actions are absent" do
    assert {:error, {:missing_option, :registry_json}} =
             Compiler.compile(encoder_model_dir: "unused", output: "unused.etf")
  end
end
