defmodule SpectreKinetic.ClassifierAxonTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Spectre.TrainClassifier
  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.Classifiers.BuiltIn
  alias SpectreKinetic.Classifiers.Internal.AxonRuntime
  alias SpectreKinetic.Classifiers.Internal.Dataset
  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.PlanConfidence.Features, as: PlanFeatures
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.Classifiers.SafetyRisk.Features, as: SafetyFeatures
  alias SpectreKinetic.Classifiers.SlotConfidence
  alias SpectreKinetic.Classifiers.SlotConfidence.Features, as: SlotFeatures
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.TestFakeAxonClassifier
  alias SpectreKinetic.TestFakeFeatureSpec
  alias SpectreKinetic.TestRegistryHelper

  defmodule CountInit do
    @behaviour SpectreKinetic.Classifier

    def init(opts) do
      agent = Keyword.fetch!(opts, :agent)
      Agent.update(agent, &(&1 + 1))
      agent
    end

    def call(context, agent) do
      {:ok,
       PlanContext.put_classifier_result(context, :count_init, %{count: Agent.get(agent, & &1)})}
    end
  end

  test "axon runtime loads artifacts and predicts normalized rows" do
    model_dir =
      write_artifacts!(PlanConfidence, %{
        "classifier" => "plan_confidence",
        "feature_dim" => PlanConfidence.feature_dim(),
        "hidden_dim" => 4
      })

    assert {:ok, runtime} = AxonRuntime.load(PlanConfidence, model_dir: model_dir)
    features = Nx.tensor([List.duplicate(0.0, PlanConfidence.feature_dim())], type: :f32)

    assert {:ok, [[score]]} = AxonRuntime.predict(runtime, features)
    assert is_float(score)
    assert score >= 0.0
    assert score <= 1.0
  end

  test "axon runtime rejects bad artifacts and metadata mismatches" do
    assert {:error, {:missing_option, :model_dir}} = AxonRuntime.load(PlanConfidence, [])

    model_dir =
      write_artifacts!(PlanConfidence, %{
        "classifier" => "slot_confidence",
        "feature_dim" => PlanConfidence.feature_dim(),
        "hidden_dim" => 4
      })

    assert {:error, {:classifier_mismatch, "slot_confidence", "plan_confidence"}} =
             AxonRuntime.load(PlanConfidence, model_dir: model_dir)
  end

  test "feature builders keep stable vector lengths" do
    context = context()

    arg_def = %{
      "name" => "path",
      "type" => "String.t()",
      "required" => true,
      "aliases" => ["file"]
    }

    assert length(PlanFeatures.build(context)) == PlanConfidence.feature_dim()
    assert length(SlotFeatures.build(context, arg_def)) == SlotConfidence.feature_dim()
    assert length(SafetyFeatures.build(context)) == SafetyRisk.feature_dim()
  end

  test "internal feature specs expose ordered names and source datasets compile to vectors" do
    for entry <- BuiltIn.all() do
      assert entry.feature_module.feature_names() == entry.classifier.feature_names()
      assert length(entry.classifier.feature_names()) == entry.classifier.feature_dim()
      assert File.exists?(entry.dataset_path)

      entry.dataset_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.each(fn line ->
        row = Jason.decode!(line)
        refute Map.has_key?(row, "features")
      end)

      entry
      |> Dataset.load!(entry.dataset_path)
      |> Enum.each(fn example ->
        assert length(example.features) == entry.classifier.feature_dim()
      end)
    end
  end

  test "internal Axon classifier macro generates boring lifecycle helpers" do
    runtime = %AxonRuntime{}

    assert TestFakeAxonClassifier.classifier_id() == "fake_axon"
    assert TestFakeAxonClassifier.feature_dim() == 2
    assert TestFakeAxonClassifier.feature_names() == [:bias, :score]
    assert TestFakeFeatureSpec.build(%{score: "0.7"}) == [1.0, 0.7]

    assert %{mode: :heuristic, opts: [fallback: :heuristic, threshold: 0.2]} =
             TestFakeAxonClassifier.init(fallback: :heuristic, threshold: 0.2)

    assert %{mode: :axon, opts: [threshold: 0.8], runtime: ^runtime} =
             TestFakeAxonClassifier.init(runtime: runtime, threshold: 0.8, ignored: true)

    assert %Axon{} =
             TestFakeAxonClassifier.build_model(%{
               "feature_dim" => TestFakeAxonClassifier.feature_dim(),
               "hidden_dim" => 2
             })
  end

  test "built-in classifiers do not package trained artifacts in source" do
    assert Path.wildcard("lib/classifiers/**/*.{etf,json}") == []
  end

  test "initialized classifier specs are reused without calling init again" do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    assert {:ok, specs} = ClassifierPipeline.init_specs([{CountInit, agent: agent}])
    assert Agent.get(agent, & &1) == 1

    assert {:ok, first} = ClassifierPipeline.run(context(), specs)
    assert {:ok, second} = ClassifierPipeline.run(context(), specs)

    assert first.classifier_results.count_init.count == 1
    assert second.classifier_results.count_init.count == 1
    assert Agent.get(agent, & &1) == 1
  end

  test "safety hard guard prevents an Axon-safe prediction from downgrading destructive actions" do
    model_dir = write_safe_safety_artifacts!()

    runtime =
      SpectreKinetic.load_runtime!(
        registry_json: TestRegistryHelper.registry_json(),
        classifiers: [{SafetyRisk, model_dir: model_dir}]
      )

    assert {:ok, action} =
             SpectreKinetic.plan(runtime, ~s(INSTALL PACKAGE WITH: PACKAGE="nginx"))

    assert action.status == :needs_confirmation
    assert action.classifier_results.safety_risk.axon_risk == :safe
    assert action.classifier_results.safety_risk.hard_guard_risk == :system_mutation
    assert action.classifier_results.safety_risk.risk == :system_mutation
  end

  test "train_classifier task writes classifier artifacts from JSONL features" do
    dataset_path = Path.join(tmp_dir("classifier-dataset"), "examples.jsonl")
    output_dir = tmp_dir("classifier-training")
    File.mkdir_p!(Path.dirname(dataset_path))

    row0 = Jason.encode!(%{"features" => List.duplicate(0.0, 12), "label" => 0})
    row1 = Jason.encode!(%{"features" => List.duplicate(1.0, 12), "label" => 1})
    File.write!(dataset_path, row0 <> "\n" <> row1 <> "\n")

    Mix.Task.reenable("spectre.train_classifier")

    TrainClassifier.run([
      "plan_confidence",
      "--dataset",
      dataset_path,
      "--out",
      output_dir,
      "--epochs",
      "1",
      "--hidden-dim",
      "4",
      "--batch-size",
      "2"
    ])

    assert File.exists?(Path.join(output_dir, "params.etf"))
    assert File.exists?(Path.join(output_dir, "metadata.json"))
    assert File.exists?(Path.join(output_dir, "calibration.json"))
  end

  test "bundled classifier datasets train all built-in classifiers" do
    output_root = tmp_dir("bundled-classifier-training")

    for %{id: classifier, dataset_path: dataset_path} <- BuiltIn.all() do
      Mix.Task.reenable("spectre.train_classifier")

      output_dir = Path.join(output_root, classifier)

      TrainClassifier.run([
        classifier,
        "--dataset",
        dataset_path,
        "--out",
        output_dir,
        "--epochs",
        "1",
        "--hidden-dim",
        "4"
      ])

      assert File.exists?(Path.join(output_dir, "params.etf"))
      assert File.exists?(Path.join(output_dir, "metadata.json"))
      assert File.exists?(Path.join(output_dir, "calibration.json"))
    end
  end

  defp write_artifacts!(classifier, metadata) do
    model_dir = tmp_dir("classifier-artifacts")
    model = classifier.build_model(metadata)
    {init_fn, _predict_fn} = Axon.build(model)

    model_state =
      init_fn.(Nx.template({1, metadata["feature_dim"]}, :f32), Axon.ModelState.empty())

    File.write!(Path.join(model_dir, "metadata.json"), Jason.encode!(metadata, pretty: true))
    File.write!(Path.join(model_dir, "params.etf"), :erlang.term_to_binary(model_state))
    File.write!(Path.join(model_dir, "calibration.json"), Jason.encode!(%{}, pretty: true))
    model_dir
  end

  defp write_safe_safety_artifacts! do
    labels = Enum.map(SafetyRisk.labels(), &Atom.to_string/1)

    metadata = %{
      "classifier" => "safety_risk",
      "feature_dim" => SafetyRisk.feature_dim(),
      "hidden_dim" => 4,
      "labels" => labels
    }

    model_dir = write_artifacts!(SafetyRisk, metadata)
    {:ok, params_binary} = File.read(Path.join(model_dir, "params.etf"))
    model_state = :erlang.binary_to_term(params_binary)

    data =
      model_state.data
      |> put_in(["dense_0", "kernel"], Nx.broadcast(0.0, {SafetyRisk.feature_dim(), 4}))
      |> put_in(["dense_0", "bias"], Nx.broadcast(0.0, {4}))
      |> put_in(["dense_1", "kernel"], Nx.broadcast(0.0, {4, length(labels)}))
      |> put_in(["dense_1", "bias"], Nx.tensor([10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]))

    File.write!(
      Path.join(model_dir, "params.etf"),
      :erlang.term_to_binary(%{model_state | data: data})
    )

    model_dir
  end

  defp context do
    runtime = SpectreKinetic.load_runtime!(registry_json: TestRegistryHelper.registry_json())

    planner_result = %{
      "status" => "ok",
      "selected_tool" => "Linux.Coreutils.ls/1",
      "args" => %{"path" => "/tmp"},
      "missing" => [],
      "confidence" => 0.85,
      "combined_score" => 0.9,
      "candidates" => [%{"id" => "Linux.Coreutils.ls/1", "score" => 0.9}]
    }

    PlanContext.from_planner_result(
      runtime,
      ~s(LIST DIRECTORY WITH: PATH="/tmp"),
      :plan,
      planner_result
    )
  end

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end
end
