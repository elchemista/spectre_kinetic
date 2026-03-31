defmodule SpectreKinetic.TestFixtures do
  @moduledoc false

  def root do
    [
      System.get_env("SPECTRE_KINETIC_FIXTURES_ROOT"),
      Path.expand("../../../spectre-kinetic", __DIR__),
      Path.expand("../../../spectre-kinetic-engine", __DIR__)
    ]
    |> Enum.find(&valid_root?/1)
  end

  def root! do
    root() ||
      raise """
      spectre-kinetic-engine fixtures are missing.

      Set SPECTRE_KINETIC_FIXTURES_ROOT to a checkout of:
      https://github.com/elchemista/spectre-kinetic-engine
      """
  end

  def skip_reason do
    if root(), do: false, else: "spectre-kinetic-engine fixtures are not available"
  end

  def model_dir do
    Path.join(root!(), "packs/minilm")
  end

  def registry_mcr do
    Path.join(root!(), "tests/test_registry.mcr")
  end

  def registry_json do
    Path.join(root!(), "tests/test_registry.json")
  end

  defp valid_root?(nil), do: false

  defp valid_root?(path) do
    File.dir?(path) and
      File.exists?(Path.join(path, "packs/minilm/pack.json")) and
      File.exists?(Path.join(path, "tests/test_registry.mcr"))
  end
end
