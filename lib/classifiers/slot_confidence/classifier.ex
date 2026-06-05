defmodule SpectreKinetic.Classifiers.SlotConfidence do
  @moduledoc """
  Axon-backed confidence classifier for already-mapped slots.
  """

  alias SpectreKinetic.Classifiers.Internal.AxonClassifier
  alias SpectreKinetic.Classifiers.SlotConfidence.Features
  alias SpectreKinetic.PlanContext

  use AxonClassifier,
    id: "slot_confidence",
    features: Features,
    output: :binary,
    opts: [:min_slot_confidence, :low_confidence_status],
    load_error: "failed to load slot confidence classifier"

  @default_min_slot_confidence 0.70

  @impl SpectreKinetic.Classifier
  def call(%PlanContext{} = context, state) do
    case PlanContext.selected_action(context) do
      nil ->
        {:ok,
         PlanContext.put_classifier_result(context, :slot_confidence, %{
           slots: %{},
           min_confidence: nil,
           decision: :unavailable
         })}

      action ->
        with {:ok, result} <- classify_slots(context, action, state) do
          context =
            context
            |> PlanContext.put_classifier_result(:slot_confidence, result)
            |> maybe_update_status(result, state_opts(state))

          {:ok, context}
        end
    end
  end

  @doc """
  Estimates confidence for one mapped slot without a model artifact.
  """
  @spec heuristic_slot_confidence(PlanContext.t(), map()) :: {float(), binary() | nil}
  def heuristic_slot_confidence(context, arg_def), do: slot_confidence(context, arg_def)

  defp classify_slots(context, action, state) do
    arg_defs = action["args"] || []
    opts = state_opts(state)
    threshold = Keyword.get(opts, :min_slot_confidence, @default_min_slot_confidence)

    with {:ok, slots} <- build_slots(context, arg_defs, state) do
      required_confidences =
        slots
        |> Enum.filter(fn {_name, slot} -> slot.required end)
        |> Enum.map(fn {_name, slot} -> slot.confidence end)

      confidences = Enum.map(slots, fn {_name, slot} -> slot.confidence end)
      min_confidence = if confidences == [], do: 1.0, else: Enum.min(confidences)

      required_min_confidence =
        if required_confidences == [], do: 1.0, else: Enum.min(required_confidences)

      {:ok,
       %{
         slots: Map.new(slots),
         min_confidence: min_confidence,
         required_min_confidence: required_min_confidence,
         decision:
           if(required_min_confidence < threshold, do: :needs_clarification, else: :accept)
       }}
    end
  end

  defp build_slots(context, arg_defs, %{mode: :axon, runtime: runtime}) do
    arg_defs
    |> Enum.reduce_while({:ok, []}, fn arg_def, {:ok, acc} ->
      name = arg_def["name"]
      source = Features.exact_or_alias_source(PlanContext.parsed_args(context), arg_def)

      case AxonClassifier.predict_one(runtime, Features.build(context, arg_def)) do
        {:ok, [confidence]} ->
          slot = {name, slot_result(confidence, source, arg_def)}
          {:cont, {:ok, [slot | acc]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> built_slots()
  end

  defp build_slots(context, arg_defs, %{mode: :heuristic}) do
    {:ok,
     Enum.map(arg_defs, fn arg_def ->
       name = arg_def["name"]
       {confidence, source} = slot_confidence(context, arg_def)
       {name, slot_result(confidence, source, arg_def)}
     end)}
  end

  defp built_slots({:ok, slots}), do: {:ok, Enum.reverse(slots)}
  defp built_slots({:error, _reason} = error), do: error

  defp slot_confidence(context, arg_def) do
    name = arg_def["name"]
    missing_fields = PlanContext.missing_fields(context)
    args = PlanContext.args(context)

    cond do
      name in missing_fields ->
        {0.0, nil}

      not Map.has_key?(args, name) ->
        {0.0, nil}

      source = Features.exact_or_alias_source(PlanContext.parsed_args(context), arg_def) ->
        {source_confidence(source, name), source}

      Features.type_shape_match?(Map.get(args, name), arg_def) ->
        {0.82, nil}

      true ->
        {0.72, nil}
    end
  end

  defp source_confidence(source, name) do
    if source == String.downcase(name), do: 0.98, else: 0.93
  end

  defp slot_result(confidence, source, arg_def) do
    %{
      confidence: clamp(confidence),
      source: source,
      required: Map.get(arg_def, "required", true)
    }
  end

  defp maybe_update_status(
         context,
         %{required_min_confidence: required_min_confidence} = result,
         opts
       )
       when is_number(required_min_confidence) do
    threshold = Keyword.get(opts, :min_slot_confidence, @default_min_slot_confidence)

    cond do
      context.status == :ok and required_min_confidence < threshold ->
        context
        |> Map.put(:status, Keyword.get(opts, :low_confidence_status, :needs_clarification))
        |> PlanContext.add_warning("one or more required mapped slots have low confidence")

      context.status == :ok and result.min_confidence < threshold ->
        PlanContext.add_warning(context, "one or more optional mapped slots have low confidence")

      true ->
        context
    end
  end

  defp maybe_update_status(context, %{min_confidence: min_confidence}, opts)
       when is_number(min_confidence) do
    threshold = Keyword.get(opts, :min_slot_confidence, @default_min_slot_confidence)

    if context.status == :ok and min_confidence < threshold do
      context
      |> Map.put(:status, Keyword.get(opts, :low_confidence_status, :needs_confirmation))
      |> PlanContext.add_warning("one or more mapped slots have low confidence")
    else
      context
    end
  end

  defp maybe_update_status(context, _result, _opts), do: context

  defp state_opts(%{opts: opts}), do: opts
  defp state_opts(opts) when is_list(opts), do: opts

  defp clamp(value) when value < 0.0, do: 0.0
  defp clamp(value) when value > 1.0, do: 1.0
  defp clamp(value), do: value
end
