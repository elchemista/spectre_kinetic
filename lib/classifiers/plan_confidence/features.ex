defmodule SpectreKinetic.Classifiers.PlanConfidence.Features do
  @moduledoc """
  Stable 12-dimensional feature vector for plan confidence.
  """

  alias SpectreKinetic.Classifiers.Internal.FeatureVector
  alias SpectreKinetic.PlanContext

  use SpectreKinetic.Classifiers.Internal.FeatureSpec

  feature(:combined_score, :combined_score_feature)
  feature(:confidence, :confidence_feature)
  feature(:tool_score, :tool_score_feature)
  feature(:mapping_score, :mapping_score_feature)
  feature(:top1_score, :top1_score_feature)
  feature(:top2_score, :top2_score_feature)
  feature(:margin, :margin_feature)
  feature(:missing_count, :missing_count_feature)
  feature(:ranked_tool_count, :ranked_tool_count_feature)
  feature(:mapped_arg_count, :mapped_arg_count_feature)
  feature(:selected_tool, :selected_tool_feature)
  feature(:status, :status_feature)

  @typep plan_features :: %{
           required(:args) => map(),
           required(:missing) => [binary()],
           required(:ranked_tools) => [map()],
           required(:scores) => map(),
           required(:selected_tool) => binary() | nil,
           required(:status) => atom()
         }

  @doc """
  Builds the numeric feature vector for plan confidence.
  """
  @spec build(PlanContext.t()) :: [float()]
  def build(%PlanContext{} = context) do
    context
    |> plan_features()
    |> feature_values()
  end

  @spec plan_features(PlanContext.t()) :: plan_features()
  defp plan_features(%PlanContext{} = context) do
    %{
      args: PlanContext.args(context),
      missing: PlanContext.missing_fields(context),
      ranked_tools: PlanContext.ranked_tools(context),
      scores: PlanContext.scores(context),
      selected_tool: PlanContext.selected_tool(context),
      status: context.status
    }
  end

  @spec combined_score_feature(plan_features()) :: float()
  defp combined_score_feature(features), do: score_feature(features, :combined_score)

  @spec confidence_feature(plan_features()) :: float()
  defp confidence_feature(features), do: score_feature(features, :confidence)

  @spec tool_score_feature(plan_features()) :: float()
  defp tool_score_feature(features), do: score_feature(features, :tool_score)

  @spec mapping_score_feature(plan_features()) :: float()
  defp mapping_score_feature(features), do: score_feature(features, :mapping_score)

  @spec top1_score_feature(plan_features()) :: float()
  defp top1_score_feature(features), do: score_feature(features, :top1_score)

  @spec top2_score_feature(plan_features()) :: float()
  defp top2_score_feature(features), do: score_feature(features, :top2_score)

  @spec margin_feature(plan_features()) :: float()
  defp margin_feature(features), do: score_feature(features, :margin)

  @spec score_feature(plan_features(), atom()) :: float()
  defp score_feature(%{scores: scores}, key), do: FeatureVector.number(scores[key])

  @spec missing_count_feature(plan_features()) :: float()
  defp missing_count_feature(%{missing: missing}), do: FeatureVector.ratio(length(missing), 10)

  @spec ranked_tool_count_feature(plan_features()) :: float()
  defp ranked_tool_count_feature(%{ranked_tools: ranked_tools}) do
    FeatureVector.ratio(length(ranked_tools), 20)
  end

  @spec mapped_arg_count_feature(plan_features()) :: float()
  defp mapped_arg_count_feature(%{args: args}), do: FeatureVector.ratio(map_size(args), 20)

  @spec selected_tool_feature(plan_features()) :: float()
  defp selected_tool_feature(%{selected_tool: selected_tool}) do
    FeatureVector.presence(selected_tool)
  end

  @spec status_feature(plan_features()) :: float()
  defp status_feature(%{status: status}), do: FeatureVector.status(status)
end
