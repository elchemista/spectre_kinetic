defmodule SpectreKinetic.ClassifierPipelineTest do
  use ExUnit.Case, async: true

  alias SpectreKinetic.ClassifierPipeline
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.Planner.Runtime, as: PlannerRuntime

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

  defmodule StatusClassifier do
    @behaviour SpectreKinetic.Classifier

    def init(opts), do: Keyword.fetch!(opts, :status)
    def call(context, status), do: {:ok, %{context | status: status}}
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
    assert context.status == :needs_confirmation
    assert context.warnings == ["halted"]
    refute Map.has_key?(context.classifier_results, :after_halt)
  end

  test "returns classifier errors with the module attached" do
    assert {:error, {ErrorClassifier, :boom}} =
             ClassifierPipeline.run(context(), [ErrorClassifier])
  end

  test "a later classifier cannot downgrade a restrictive status to ok" do
    assert {:ok, context} =
             ClassifierPipeline.run(context(), [
               {StatusClassifier, status: :needs_clarification},
               {StatusClassifier, status: :ok}
             ])

    assert context.status == :needs_clarification
  end

  test "invalid classifier statuses fail closed" do
    assert {:ok, context} =
             ClassifierPipeline.run(context(), [{StatusClassifier, status: :unknown_status}])

    assert context.status == :error
  end

  test "invalid planner statuses normalize to error" do
    for invalid <- [nil, 123, %{}, :unknown_status] do
      context =
        PlanContext.from_planner_result(
          %PlannerRuntime{},
          "TEST",
          :plan,
          %{"status" => invalid}
        )

      assert context.status == :error
    end
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
