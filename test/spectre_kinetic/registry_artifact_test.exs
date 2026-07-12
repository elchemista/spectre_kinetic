defmodule SpectreKinetic.RegistryArtifactTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Registry.ETS

  test "compiled registries reject unknown atoms without mutating live tables" do
    {:ok, registry} = ETS.new()
    {:ok, registry} = ETS.upsert_action(registry, action(), nil)
    path = temp_path("unknown-atom.etf")

    atom_name =
      "spectre_kinetic_untrusted_registry_#{System.unique_integer([:positive, :monotonic])}"

    File.write!(path, <<131, 118, byte_size(atom_name)::16, atom_name::binary>>)

    assert {:error, {:bad_etf, {:invalid_artifact_term, %ArgumentError{}}}} =
             ETS.load_compiled(registry, path)

    assert ETS.action_count(registry) == 1
    assert ETS.get_action(registry, "Example.run/0")["name"] == "run"
    assert :ok = ETS.close(registry)
  end

  test "compiled registries return structured errors for malformed ETF" do
    {:ok, registry} = ETS.new()
    path = temp_path("malformed.etf")
    File.write!(path, <<131, 255, 0, 1>>)

    assert {:error, {:bad_etf, {:invalid_artifact_term, %ArgumentError{}}}} =
             ETS.load_compiled(registry, path)

    assert :ok = ETS.close(registry)
  end

  defp action do
    %{
      id: "Example.run/0",
      module: "Example",
      name: "run",
      arity: 0,
      args: [],
      examples: ["RUN EXAMPLE"]
    }
  end

  defp temp_path(file_name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-kinetic-registry-artifact-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, file_name)
  end
end
