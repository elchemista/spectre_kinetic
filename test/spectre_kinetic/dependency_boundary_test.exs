defmodule SpectreKinetic.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  test "Spectre is fetched from GitHub only for integration tests" do
    config = Mix.Project.config()
    deps = Keyword.fetch!(config, :deps)

    assert {:spectre, opts} = Enum.find(deps, &(elem(&1, 0) == :spectre))
    assert opts[:github] == "elchemista/spectre"
    assert opts[:tag] == "0.2.0"
    assert opts[:only] == :test
    refute Keyword.has_key?(opts, :path)
    refute Keyword.has_key?(opts, :hex)
    refute Keyword.has_key?(config, :package)
  end
end
