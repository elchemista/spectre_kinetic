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

  test "compiled registries enforce bundle versions before installation" do
    {:ok, registry} = ETS.new()
    path = temp_path("wrong-version.etf")

    write_bundle(path, %{version: 2, actions: [action()]})

    assert {:error, {:unsupported_bundle_version, 2, 1}} =
             ETS.load_compiled(registry, path)

    write_bundle(path, %{actions: [action()]})

    assert {:error, {:missing_bundle_field, :version}} =
             ETS.load_compiled(registry, path)

    assert ETS.action_count(registry) == 0
    assert :ok = ETS.close(registry)
  end

  test "compiled registries reject incoherent embedding metadata" do
    {:ok, registry} = ETS.new()
    path = temp_path("bad-embeddings.etf")

    write_bundle(path, %{
      version: 1,
      actions: [action()],
      action_ids: ["Example.run/0", "Example.run/0"],
      tool_embeddings: [Nx.tensor([1.0, 0.0]), Nx.tensor([0.0, 1.0])],
      embedding_dim: 2
    })

    assert {:error, :duplicate_embedding_action} = ETS.load_compiled(registry, path)

    write_bundle(path, %{
      version: 1,
      actions: [action()],
      action_ids: ["Example.run/0"],
      tool_embeddings: [Nx.tensor([[1.0, 0.0]])],
      embedding_dim: 2
    })

    assert {:error, {:invalid_embedding, 0, 2}} = ETS.load_compiled(registry, path)
    assert ETS.action_count(registry) == 0
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

  defp write_bundle(path, fields) do
    bundle =
      Map.merge(
        %{action_ids: [], tool_embeddings: [], embedding_dim: nil},
        fields
      )

    File.write!(path, :erlang.term_to_binary(bundle, [:compressed]))
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
