defmodule SpectreKinetic.ClassifierPrimitivesContractTest.PlanFeatures do
  @moduledoc false

  def build(context) do
    send(self(), {:dataset_context, context})
    [1.0]
  end
end

defmodule SpectreKinetic.ClassifierPrimitivesContractTest.SlotFeatures do
  @moduledoc false

  def build(context, arg) do
    send(self(), {:dataset_slot_context, context, arg})
    [2.0]
  end
end

defmodule SpectreKinetic.ClassifierPrimitivesContractTest.PairEmbedding do
  @moduledoc false

  def embed_batch(:fake, texts) do
    {:ok,
     Nx.tensor(
       Enum.map(texts, fn
         "query" -> [1.0, 2.0]
         "tool" -> [0.5, 3.0]
       end)
     )}
  end
end

defmodule SpectreKinetic.ClassifierPrimitivesContractTest.InvalidReturnClassifier do
  @moduledoc false

  def init(_opts), do: :state
  def call(_context, :state), do: :invalid_return
end

defmodule SpectreKinetic.ClassifierPrimitivesContractTest.RaisingClassifier do
  @moduledoc false

  def init(_opts), do: :state
  def call(_context, :state), do: raise("classifier exploded")
end

defmodule SpectreKinetic.ClassifierPrimitivesContractTest.RestrictiveHaltClassifier do
  @moduledoc false

  def init(_opts), do: :state
  def call(context, :state), do: {:halt, context}
end

defmodule SpectreKinetic.ClassifierPrimitivesContractTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.ClassifierPipeline.Spec
  alias SpectreKinetic.ClassifierPrimitivesContractTest.InvalidReturnClassifier
  alias SpectreKinetic.ClassifierPrimitivesContractTest.PairEmbedding
  alias SpectreKinetic.ClassifierPrimitivesContractTest.PlanFeatures
  alias SpectreKinetic.ClassifierPrimitivesContractTest.RaisingClassifier
  alias SpectreKinetic.ClassifierPrimitivesContractTest.RestrictiveHaltClassifier
  alias SpectreKinetic.ClassifierPrimitivesContractTest.SlotFeatures
  alias SpectreKinetic.Classifiers.BuiltIn
  alias SpectreKinetic.Classifiers.Internal.Dataset
  alias SpectreKinetic.Classifiers.Internal.FeatureVector
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.Reranker.Calibration
  alias SpectreKinetic.Reranker.FeatureBuilder

  test "feature declarations preserve vector order and derive dimensions at compile time" do
    module =
      Module.concat([
        __MODULE__,
        String.to_atom("FeatureSpec#{System.unique_integer([:positive])}")
      ])

    Code.compile_string("""
    defmodule #{inspect(module)} do
      use SpectreKinetic.Classifiers.Internal.FeatureSpec

      feature :present, :present
      feature :score, :score

      def build(features), do: feature_values(features)
      defp present(features), do: if(features[:value], do: 1.0, else: 0.0)
      defp score(features), do: features[:score] * 1.0
    end
    """)

    assert module.feature_names() == [:present, :score]
    assert module.dim() == 2
    assert module.build(%{value: true, score: 0.75}) == [1.0, 0.75]
  end

  test "feature scalar conversion is total and never leaks hostile source types" do
    assert FeatureVector.number(2) == 2.0
    assert FeatureVector.number(2.5) == 2.5
    assert FeatureVector.number(true) == 1.0
    assert FeatureVector.number(false) == 0.0
    assert FeatureVector.number(nil) == 0.0
    assert FeatureVector.number("2.75") == 2.75
    assert FeatureVector.number("2.75 trailing") == 0.0
    assert FeatureVector.number({:unexpected, :term}) == 0.0

    for empty <- [nil, "", [], %{}] do
      assert FeatureVector.presence(empty) == 0.0
    end

    assert FeatureVector.presence("value") == 1.0
  end

  test "feature bounds and tensor dimensions encode the closed numeric contract" do
    assert FeatureVector.clamp(-2, 0, 10) == 0.0
    assert FeatureVector.clamp(12, 0, 10) == 10.0
    assert FeatureVector.clamp(4, 0, 10) == 4.0
    assert FeatureVector.ratio(10, 0) == 0.0
    assert FeatureVector.ratio(15, 10) == 1.0
    assert FeatureVector.ratio(-2, 10) == 0.0
    assert FeatureVector.bool(true) == 1.0
    assert FeatureVector.bool(false) == 0.0
    assert FeatureVector.status(:ok) == 1.0
    assert FeatureVector.status(:needs_confirmation) == 0.6
    assert FeatureVector.status(:needs_clarification) == 0.3
    assert FeatureVector.status(:error) == 0.0

    assert {:ok, tensor} = FeatureVector.tensor([true, "0.5"], 2)
    assert Nx.to_flat_list(tensor) == [1.0, 0.5]

    assert FeatureVector.tensor([1.0], 2) == {:error, {:feature_dim_mismatch, 2, 1}}
  end

  test "dataset compilation normalizes planner statuses without creating atoms" do
    rows = [
      %{
        "input" => "missing",
        "mode" => "plan_chain",
        "planner_result" => %{"status" => "MISSING_ARGS"},
        "label" => 0
      },
      %{"al" => "ambiguous", "status" => "AMBIGUOUS_MAPPING", "label" => 1},
      %{"input" => "known", "status" => "no_tool", "label" => 0},
      %{"input" => "unknown", "status" => "NEVER_CREATE_THIS_ATOM", "label" => 0}
    ]

    path = write_jsonl("plan-contexts.jsonl", rows)
    entry = %{id: "plan_confidence", feature_module: PlanFeatures}

    assert Dataset.load!(entry, path) == [
             %{features: [1.0], label: 0},
             %{features: [1.0], label: 1},
             %{features: [1.0], label: 0},
             %{features: [1.0], label: 0}
           ]

    assert_receive {:dataset_context, first}
    assert first.mode == :plan_chain
    assert first.status == :missing_args
    assert first.planner_result["action"] == nil

    assert_receive {:dataset_context, second}
    assert second.status == :ambiguous_mapping
    assert_receive {:dataset_context, third}
    assert third.status == :no_tool
    assert_receive {:dataset_context, fourth}
    assert fourth.status == :ok
  end

  test "slot datasets retain the source argument alongside normalized context" do
    row = %{
      "input" => "send mail",
      "status" => "needs_confirmation",
      "arg" => %{"name" => "to", "required" => true},
      "label" => 1
    }

    path = write_jsonl("slot-context.jsonl", [row])
    entry = %{id: "slot_confidence", feature_module: SlotFeatures}

    assert Dataset.load!(entry, path) == [%{features: [2.0], label: 1}]

    assert_receive {:dataset_slot_context, context, arg}
    assert context.status == :needs_confirmation
    assert arg == row["arg"]
  end

  test "reranker calibration handles mixed key formats, truthy labels, and absent scores" do
    calibration =
      Calibration.build(
        [
          %{score: 0.9, label: 1},
          %{score: 0.8, label: true},
          %{"score" => 0.7, "label" => 1.0},
          %{"score" => 0.2, "label" => 0},
          %{score: 0.1, label: false},
          %{label: 1},
          %{"unrelated" => true}
        ],
        positive_quantile: 0.5
      )

    assert calibration.positive_count == 3
    assert calibration.negative_count == 2
    assert calibration.reranker_accept_threshold == 0.8
    assert calibration.reranker_reject_threshold == 0.2
    assert is_binary(calibration.generated_at)

    assert %{
             positive_count: 0,
             negative_count: 0,
             reranker_accept_threshold: nil,
             reranker_reject_threshold: nil
           } = Calibration.build([])
  end

  test "built-in classifier registry has stable ids and explicit unknown handling" do
    assert BuiltIn.ids() == ["plan_confidence", "slot_confidence", "safety_risk"]
    assert {:ok, plan_entry} = BuiltIn.fetch("plan_confidence")
    assert BuiltIn.fetch!("plan_confidence") == plan_entry
    assert BuiltIn.fetch("not-a-classifier") == :error

    assert_raise ArgumentError, ~r/unsupported classifier/, fn ->
      BuiltIn.fetch!("not-a-classifier")
    end
  end

  test "reranker pair features retain query, tool, distance, and interaction signals" do
    examples = [%{query: "query", tool_card: "tool"}]

    assert {:ok, matrix} =
             FeatureBuilder.build_matrix(:fake, examples, embedding_module: PairEmbedding)

    assert Nx.shape(matrix) == {1, 8}
    assert Nx.to_flat_list(matrix) == [1.0, 2.0, 0.5, 3.0, 0.5, 1.0, 0.5, 6.0]
    assert FeatureBuilder.feature_dim(2) == 8
  end

  test "classifier pipeline rejects invalid declarations and contains bad callbacks" do
    context = %PlanContext{
      input: "SEND EMAIL",
      mode: :plan,
      planner_result: %{},
      status: :needs_clarification,
      metadata: %{}
    }

    invalid_spec = %Spec{module: String, state: nil}

    assert ClassifierPipeline.init_specs([invalid_spec]) ==
             {:error, {:invalid_classifier_spec, invalid_spec}}

    assert ClassifierPipeline.run(context, [123]) ==
             {:error, {:invalid_classifier_spec, 123}}

    assert ClassifierPipeline.run(context, [InvalidReturnClassifier]) ==
             {:error, {InvalidReturnClassifier, {:invalid_classifier_return, :invalid_return}}}

    assert {:error, {RaisingClassifier, %RuntimeError{message: "classifier exploded"}}} =
             ClassifierPipeline.run(context, [RaisingClassifier])

    assert {:ok, halted} =
             ClassifierPipeline.run(context, [RestrictiveHaltClassifier])

    assert halted.halted?
    assert halted.status == :needs_clarification
  end

  defp write_jsonl(name, rows) do
    root =
      Path.join(
        System.tmp_dir!(),
        "spectre-classifier-primitives-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    path = Path.join(root, name)
    File.write!(path, Enum.map_join(rows, "\n", &Jason.encode!/1) <> "\n")
    path
  end
end
