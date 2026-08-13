defmodule SpectreKinetic.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  test "Spectre comes from Hex while Kinetic remains GitHub-only" do
    config = Mix.Project.config()
    deps = Keyword.fetch!(config, :deps)

    assert {:spectre, "~> 0.3.0", opts} = Enum.find(deps, &(elem(&1, 0) == :spectre))
    assert opts[:only] == :test
    refute Keyword.has_key?(opts, :github)
    refute Keyword.has_key?(opts, :path)

    refute Keyword.has_key?(config, :package)
  end
end
