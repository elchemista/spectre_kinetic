defmodule SpectreKinetic.DependencyBoundaryTest do
  use ExUnit.Case, async: true

  test "Spectre is fetched from GitHub only for integration tests" do
    deps = Mix.Project.config() |> Keyword.fetch!(:deps)

    assert {:spectre, opts} = Enum.find(deps, &(elem(&1, 0) == :spectre))
    assert opts[:github] == "elchemista/spectre"
    assert opts[:branch] == "main"
    assert opts[:only] == :test
    refute Keyword.has_key?(opts, :hex)
  end
end
