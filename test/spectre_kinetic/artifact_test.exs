defmodule SpectreKinetic.ArtifactTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Artifact

  test "safely decodes ordinary artifact data" do
    artifact = %{version: 1, labels: ["safe"], values: [1.0, 2.0]}

    assert {:ok, ^artifact} =
             artifact
             |> :erlang.term_to_binary([:compressed])
             |> Artifact.decode_term()
  end

  test "rejects atoms that do not already exist in the VM" do
    atom_name =
      "spectre_kinetic_untrusted_atom_#{System.unique_integer([:positive, :monotonic])}"

    binary = <<131, 118, byte_size(atom_name)::16, atom_name::binary>>

    assert {:error, {:invalid_artifact_term, %ArgumentError{}}} =
             Artifact.decode_term(binary)
  end

  test "rejects oversized binaries before decoding" do
    binary = :erlang.term_to_binary(%{payload: String.duplicate("x", 128)})

    assert {:error, {:artifact_too_large, :binary, size, 16}} =
             Artifact.decode_term(binary, max_bytes: 16)

    assert size == byte_size(binary)
  end

  test "enforces file limits for ETF and JSON artifacts" do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-kinetic-artifact-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    term_path = Path.join(root, "params.etf")
    json_path = Path.join(root, "metadata.json")
    File.write!(term_path, :erlang.term_to_binary(%{safe: true}))
    File.write!(json_path, Jason.encode!(%{"version" => 1}))

    assert {:ok, %{safe: true}} = Artifact.read_term(term_path)
    assert {:ok, %{"version" => 1}} = Artifact.read_json(json_path)

    assert {:error, {:artifact_too_large, ^term_path, _size, 4}} =
             Artifact.read_term(term_path, max_bytes: 4)

    assert {:error, {:artifact_too_large, ^json_path, _size, 4}} =
             Artifact.read_json(json_path, max_bytes: 4)
  end
end
