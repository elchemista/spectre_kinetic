defmodule SpectreKinetic.Classifiers.PlanConfidence do
  @moduledoc """
  Axon-backed planning-confidence classifier.
  """

  alias SpectreKinetic.Classifiers.Internal.AxonClassifier
  alias SpectreKinetic.Classifiers.PlanConfidence.Features
  alias SpectreKinetic.PlanContext

  use AxonClassifier,
    id: "plan_confidence",
    features: Features,
    output: :binary,
    opts: [:accept_threshold, :clarify_threshold, :override_terminal_statuses],
    load_error: "failed to load plan confidence classifier"

  @default_accept_threshold 0.80
  @default_clarify_threshold 0.55
  @terminal_statuses [:no_tool, :missing_args, :error]

  @impl true
  def call(%PlanContext{} = context, %{mode: :axon, runtime: runtime, opts: opts}) do
    with {:ok, [confidence]} <- AxonClassifier.predict_one(runtime, Features.build(context)) do
      write_result(context, confidence, opts)
    end
  end

  def call(%PlanContext{} = context, %{mode: :heuristic, opts: opts}) do
    write_result(context, heuristic_confidence(context), opts)
  end

  def call(%PlanContext{} = context, opts) do
    write_result(context, heuristic_confidence(context), opts)
  end

  @doc """
  Estimates plan confidence without a model artifact.
  """
  @spec heuristic_confidence(PlanContext.t()) :: float()
  def heuristic_confidence(context), do: estimate_confidence(context)

  defp write_result(context, confidence, opts) do
    confidence = clamp(confidence)
    decision = decision(confidence, opts)
    scores = PlanContext.scores(context)
    missing_fields = PlanContext.missing_fields(context)
    ranked_tools = PlanContext.ranked_tools(context)

    result = %{
      confidence: confidence,
      decision: decision,
      margin: scores[:margin],
      missing_required_count: length(missing_fields),
      ranked_tool_count: length(ranked_tools)
    }

    context =
      context
      |> PlanContext.put_classifier_result(:plan_confidence, result)
      |> maybe_update_status(decision, opts)

    {:ok, context}
  end

  defp estimate_confidence(context) do
    scores = PlanContext.scores(context)

    base =
      scores[:combined_score] ||
        scores[:confidence] ||
        scores[:top1_score] ||
        0.0

    missing_penalty = length(PlanContext.missing_fields(context)) * 0.15

    margin_bonus =
      case scores[:margin] do
        margin when is_number(margin) -> min(max(margin, 0.0), 0.2)
        _ -> 0.0
      end

    base
    |> Kernel.+(margin_bonus)
    |> Kernel.-(missing_penalty)
    |> clamp()
  end

  defp decision(confidence, opts) do
    accept_threshold = Keyword.get(opts, :accept_threshold, @default_accept_threshold)
    clarify_threshold = Keyword.get(opts, :clarify_threshold, @default_clarify_threshold)

    cond do
      confidence >= accept_threshold -> :accept
      confidence >= clarify_threshold -> :needs_confirmation
      true -> :needs_clarification
    end
  end

  defp maybe_update_status(%PlanContext{} = context, :accept, _opts), do: context

  defp maybe_update_status(%PlanContext{} = context, decision, opts) do
    if mutable_status?(context.status, opts) do
      %{context | status: decision}
    else
      context
    end
  end

  defp mutable_status?(:ok, _opts), do: true

  defp mutable_status?(status, opts),
    do: Keyword.get(opts, :override_terminal_statuses, false) && status in @terminal_statuses

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
