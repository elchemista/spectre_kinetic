defmodule SpectreKinetic.ClassifierPipelineTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.PlanContext

  defmodule AppendResult do
    @behaviour SpectreKinetic.Classifier

    def init(opts), do: opts

    def call(context, opts) do
      key = Keyword.fetch!(opts, :key)
      value = Keyword.fetch!(opts, :value)

      {:ok,
       PlanContext.put_classifier_result(context, key, %{
         value: value
       })}
    end
  end

  defmodule HaltClassifier do
    @behaviour SpectreKinetic.Classifier

    def init(opts), do: opts

    def call(context, _opts) do
      {:halt, PlanContext.add_warning(context, "halted")}
    end
  end

  defmodule ErrorClassifier do
    @behaviour SpectreKinetic.Classifier

    def init(opts), do: opts
    def call(_context, _opts), do: {:error, :boom}
  end

  test "runs classifiers in order and passes initialized opts" do
    context = context()

    assert {:ok, context} =
             ClassifierPipeline.run(context, [
               {AppendResult, key: :first, value: 1},
               {AppendResult, key: :second, value: 2}
             ])

    assert context.classifier_results.first == %{value: 1}
    assert context.classifier_results.second == %{value: 2}
    refute context.halted?
  end

  test "halts successfully and marks the context" do
    assert {:ok, context} =
             ClassifierPipeline.run(context(), [
               HaltClassifier,
               {AppendResult, key: :after_halt, value: 1}
             ])

    assert context.halted?
    assert context.warnings == ["halted"]
    refute Map.has_key?(context.classifier_results, :after_halt)
  end

  test "returns classifier errors with the module attached" do
    assert {:error, {ErrorClassifier, :boom}} =
             ClassifierPipeline.run(context(), [ErrorClassifier])
  end

  defp context do
    %PlanContext{
      input: "TEST",
      mode: :plan,
      planner_result: %{"status" => "ok"},
      status: :ok,
      metadata: %{},
      classifier_results: %{},
      warnings: [],
      halted?: false
    }
  end
end
