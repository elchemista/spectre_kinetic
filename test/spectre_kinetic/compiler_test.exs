defmodule SpectreKinetic.Planner.CompilerTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Planner.Compiler
  alias SpectreKinetic.Planner.Registry.ETS

  defmodule FakeEmbedding do
    def load(encoder_model_dir: "test://compiler"), do: {:ok, :fake}
    def dim(:fake), do: 2

    def embed_batch(:fake, texts) do
      {:ok, Nx.tensor(Enum.map(texts, fn _text -> [1.0, 0.0] end), type: :f32)}
    end
  end

  defmodule FailingEmbedding do
    def load(encoder_model_dir: "test://compiler"), do: {:ok, :fake}
    def dim(:fake), do: 2
    def embed_batch(:fake, _texts), do: {:error, :embedding_failed}
  end

  defmodule UnexpectedLoadEmbedding do
    def load(encoder_model_dir: "test://compiler"), do: :loaded_without_tuple
  end

  test "compile/1 rejects non-list inline actions before loading artifacts" do
    assert {:error, {:invalid_option, :actions}} =
             Compiler.compile(actions: :nope, encoder_model_dir: "unused", output: "unused.etf")
  end

  test "compile/1 still requires registry_json when inline actions are absent" do
    assert {:error, {:missing_option, :registry_json}} =
             Compiler.compile(encoder_model_dir: "unused", output: "unused.etf")
  end

  test "compile/1 validates empty input and batch size before loading a model" do
    assert {:error, :empty_registry} =
             Compiler.compile(
               actions: [],
               encoder_model_dir: "test://compiler",
               output: temp_path("empty.etf"),
               embedding_module: FakeEmbedding
             )

    assert {:error, {:invalid_option, :batch_size, 0}} =
             Compiler.compile(
               actions: [action()],
               encoder_model_dir: "test://compiler",
               output: temp_path("invalid-batch.etf"),
               batch_size: 0,
               embedding_module: FakeEmbedding
             )
  end

  test "compile/1 writes a versioned bundle atomically" do
    output = temp_path("registry.etf")

    assert :ok =
             Compiler.compile(
               actions: [action()],
               encoder_model_dir: "test://compiler",
               output: output,
               batch_size: 1,
               embedding_module: FakeEmbedding
             )

    assert {:ok, bundle} = SpectreKinetic.Artifact.read_term(output)
    assert bundle["version"] == 2
    assert bundle["action_ids"] == ["Example.run/0"]
    assert bundle["embedding_dim"] == 2
    assert bundle["embedding_dtype"] == "f32"
    assert bundle["tool_embeddings"] == [[1.0, 0.0]]
    assert Enum.all?(Map.keys(bundle), &is_binary/1)

    assert {:ok, registry} = ETS.new(compiled_registry: output)
    assert {matrix, ["Example.run/0"]} = ETS.embedding_matrix(registry)
    assert Nx.shape(matrix) == {1, 2}
    assert :ok = ETS.close(registry)

    assert Path.wildcard(Path.join(Path.dirname(output), ".registry.etf.tmp-*")) == []
  end

  test "compile/1 preserves an existing output when embedding fails" do
    output = temp_path("existing.etf")
    File.write!(output, "existing-bundle")

    assert {:error, :embedding_failed} =
             Compiler.compile(
               actions: [action()],
               encoder_model_dir: "test://compiler",
               output: output,
               embedding_module: FailingEmbedding
             )

    assert File.read!(output) == "existing-bundle"
    assert Path.wildcard(Path.join(Path.dirname(output), ".existing.etf.tmp-*")) == []
  end

  test "compile/1 closes its ETS registry when an inline action is invalid" do
    table_count = owned_table_count()
    output = temp_path("invalid-action.etf")

    assert {:error, _reason} =
             Compiler.compile(
               actions: [action(), %{}],
               encoder_model_dir: "test://compiler",
               output: output,
               embedding_module: FakeEmbedding
             )

    assert owned_table_count() == table_count
    refute File.exists?(output)
  end

  test "compile/1 rejects unexpected embedding loader returns and closes ETS" do
    table_count = owned_table_count()
    output = temp_path("invalid-loader-return.etf")

    assert {:error, {:invalid_embedding_load_result, :loaded_without_tuple}} =
             Compiler.compile(
               actions: [action()],
               encoder_model_dir: "test://compiler",
               output: output,
               embedding_module: UnexpectedLoadEmbedding
             )

    assert owned_table_count() == table_count
    refute File.exists?(output)
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
        "spectre-kinetic-compiler-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, file_name)
  end

  defp owned_table_count do
    owner = self()
    Enum.count(:ets.all(), fn table -> :ets.info(table, :owner) == owner end)
  end
end
