defmodule SpectreKinetic.TrainingValidationTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.Classifiers.Internal.Trainer, as: ClassifierTrainer
  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.Reranker.Trainer, as: RerankerTrainer

  test "reranker rejects unsafe hyperparameters before loading an encoder" do
    opts = [encoder_model_dir: "test://unused", output_dir: tmp_dir()]

    assert {:error, {:invalid_training_option, :batch_size, 0}} =
             RerankerTrainer.train(reranker_examples(), Keyword.put(opts, :batch_size, 0))

    assert {:error, {:invalid_training_option, :epochs, -1}} =
             RerankerTrainer.train(reranker_examples(), Keyword.put(opts, :epochs, -1))

    assert {:error, {:invalid_training_option, :learning_rate, 0.0}} =
             RerankerTrainer.train(
               reranker_examples(),
               Keyword.put(opts, :learning_rate, 0.0)
             )
  end

  test "reranker requires valid examples from both classes" do
    opts = [encoder_model_dir: "test://unused", output_dir: tmp_dir()]

    assert {:error, :empty_dataset} = RerankerTrainer.train([], opts)

    assert {:error, {:invalid_training_example, 0}} =
             RerankerTrainer.train([%{query: "q", tool_card: "card", label: 2}], opts)

    assert {:error, {:invalid_dataset, :requires_positive_and_negative_examples}} =
             RerankerTrainer.train([%{query: "q", tool_card: "card", label: 1}], opts)
  end

  test "classifier training rejects invalid loop options and labels" do
    output_dir = tmp_dir()
    examples = classifier_examples(PlanConfidence.feature_dim())

    assert {:error, {:invalid_training_option, :hidden_dim, 0}} =
             ClassifierTrainer.train_binary(
               PlanConfidence,
               examples,
               output_dir: output_dir,
               hidden_dim: 0
             )

    assert {:error, {:invalid_training_option, :seed, -1}} =
             ClassifierTrainer.train_binary(
               PlanConfidence,
               examples,
               output_dir: output_dir,
               seed: -1
             )

    assert {:error, {:invalid_training_label, 0}} =
             ClassifierTrainer.train_binary(
               PlanConfidence,
               [%{features: List.duplicate(0.0, PlanConfidence.feature_dim()), label: :bad}],
               output_dir: output_dir
             )
  end

  test "multiclass training validates its class schema" do
    examples = [
      %{features: List.duplicate(0.0, SafetyRisk.feature_dim()), label: :safe}
    ]

    assert {:error, {:invalid_training_option, :labels, [:safe, :safe]}} =
             ClassifierTrainer.train_multiclass(
               SafetyRisk,
               examples,
               output_dir: tmp_dir(),
               labels: [:safe, :safe]
             )
  end

  defp reranker_examples do
    [
      %{query: "send email", tool_card: "email tool", label: 1},
      %{query: "send email", tool_card: "sms tool", label: 0}
    ]
  end

  defp classifier_examples(feature_dim) do
    [
      %{features: List.duplicate(0.0, feature_dim), label: 0},
      %{features: List.duplicate(1.0, feature_dim), label: 1}
    ]
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "spectre-kinetic-training-validation-#{System.unique_integer([:positive])}"
    )
  end
end
