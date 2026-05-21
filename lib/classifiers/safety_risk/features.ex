defmodule SpectreKinetic.Classifiers.SafetyRisk.Features do
  @moduledoc """
  Numeric/rule feature vector for safety-risk classification.
  """

  alias SpectreKinetic.Classifiers.Internal.FeatureVector
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.PlanContext
  alias SpectreKinetic.Planner.Registry

  use SpectreKinetic.Classifiers.Internal.FeatureSpec

  feature(:selected_tool, :selected_tool_feature)
  feature(:input_length, :input_length_feature)
  feature(:mapped_arg_count, :mapped_arg_count_feature)
  feature(:missing_count, :missing_count_feature)
  feature(:external_side_effect_rule, :external_side_effect_rule_feature)
  feature(:destructive_rule, :destructive_rule_feature)
  feature(:financial_rule, :financial_rule_feature)
  feature(:credential_sensitive_rule, :credential_sensitive_rule_feature)
  feature(:system_mutation_rule, :system_mutation_rule_feature)
  feature(:network_action_rule, :network_action_rule_feature)
  feature(:credential_arg, :credential_arg_feature)
  feature(:path_arg, :path_arg_feature)
  feature(:url_arg, :url_arg_feature)
  feature(:force_arg, :force_arg_feature)
  feature(:status, :status_feature)
  feature(:plan_chain, :plan_chain_feature)

  @typep safety_features :: %{
           required(:args) => map(),
           required(:input) => binary(),
           required(:missing) => [binary()],
           required(:mode) => :plan | :plan_chain,
           required(:rule_scores) => map(),
           required(:selected_tool) => binary() | nil,
           required(:status) => atom()
         }

  @doc """
  Builds the numeric feature vector for safety-risk classification.
  """
  @spec build(PlanContext.t()) :: [float()]
  def build(%PlanContext{} = context) do
    context
    |> safety_features()
    |> feature_values()
  end

  @doc """
  Builds the normalized text inspected by both model features and hard guards.
  """
  @spec risk_text(PlanContext.t()) :: binary()
  def risk_text(%PlanContext{} = context) do
    action = PlanContext.selected_action(context) || %{}

    [
      context.input,
      PlanContext.selected_tool(context),
      action["id"],
      action["module"],
      action["name"],
      action["doc"],
      action["spec"],
      Registry.build_tool_card(action)
    ]
    |> Stream.concat(List.wrap(action["examples"]))
    |> Stream.reject(&is_nil/1)
    |> Enum.join(" ")
    |> String.downcase()
  end

  @spec safety_features(PlanContext.t()) :: safety_features()
  defp safety_features(%PlanContext{} = context) do
    %{
      args: PlanContext.args(context),
      input: context.input,
      missing: PlanContext.missing_fields(context),
      mode: context.mode,
      rule_scores: SafetyRisk.rule_feature_scores(risk_text(context)),
      selected_tool: PlanContext.selected_tool(context),
      status: context.status
    }
  end

  @spec selected_tool_feature(safety_features()) :: float()
  defp selected_tool_feature(%{selected_tool: selected_tool}) do
    FeatureVector.presence(selected_tool)
  end

  @spec input_length_feature(safety_features()) :: float()
  defp input_length_feature(%{input: input}), do: FeatureVector.ratio(String.length(input), 500)

  @spec mapped_arg_count_feature(safety_features()) :: float()
  defp mapped_arg_count_feature(%{args: args}), do: FeatureVector.ratio(map_size(args), 20)

  @spec missing_count_feature(safety_features()) :: float()
  defp missing_count_feature(%{missing: missing}), do: FeatureVector.ratio(length(missing), 10)

  @spec external_side_effect_rule_feature(safety_features()) :: float()
  defp external_side_effect_rule_feature(features),
    do: risk_rule_score(features, :external_side_effect)

  @spec destructive_rule_feature(safety_features()) :: float()
  defp destructive_rule_feature(features), do: risk_rule_score(features, :destructive)

  @spec financial_rule_feature(safety_features()) :: float()
  defp financial_rule_feature(features), do: risk_rule_score(features, :financial)

  @spec credential_sensitive_rule_feature(safety_features()) :: float()
  defp credential_sensitive_rule_feature(features),
    do: risk_rule_score(features, :credential_sensitive)

  @spec system_mutation_rule_feature(safety_features()) :: float()
  defp system_mutation_rule_feature(features), do: risk_rule_score(features, :system_mutation)

  @spec network_action_rule_feature(safety_features()) :: float()
  defp network_action_rule_feature(features), do: risk_rule_score(features, :network_action)

  @spec risk_rule_score(safety_features(), atom()) :: float()
  defp risk_rule_score(%{rule_scores: rule_scores}, risk), do: Map.get(rule_scores, risk, 0.0)

  @spec credential_arg_feature(safety_features()) :: float()
  defp credential_arg_feature(%{args: args}) do
    args
    |> Stream.map(fn {key, _value} -> key end)
    |> Enum.any?(&credential_key?/1)
    |> FeatureVector.bool()
  end

  @spec path_arg_feature(safety_features()) :: float()
  defp path_arg_feature(%{args: args}) do
    args
    |> Enum.any?(fn {_key, value} -> path_value?(value) end)
    |> FeatureVector.bool()
  end

  @spec url_arg_feature(safety_features()) :: float()
  defp url_arg_feature(%{args: args}) do
    args
    |> Enum.any?(fn {_key, value} -> url_value?(value) end)
    |> FeatureVector.bool()
  end

  @spec force_arg_feature(safety_features()) :: float()
  defp force_arg_feature(%{args: args}) do
    args
    |> Enum.any?(fn {key, value} -> force_arg?(key, value) end)
    |> FeatureVector.bool()
  end

  @spec credential_key?(term()) :: boolean()
  defp credential_key?(key) do
    key = String.downcase(to_string(key))

    String.contains?(key, "password") or String.contains?(key, "token") or
      String.contains?(key, "secret")
  end

  @spec path_value?(term()) :: boolean()
  defp path_value?(value), do: is_binary(value) and String.starts_with?(value, ["/", "~"])

  @spec url_value?(term()) :: boolean()
  defp url_value?(value), do: is_binary(value) and String.match?(value, ~r/^https?:\/\//i)

  @spec force_arg?(term(), term()) :: boolean()
  defp force_arg?(key, value) do
    String.downcase(to_string(key)) in ~w(force confirm confirmed) and
      value in [true, "true", "yes", "1", 1]
  end

  @spec status_feature(safety_features()) :: float()
  defp status_feature(%{status: status}), do: FeatureVector.status(status)

  @spec plan_chain_feature(safety_features()) :: float()
  defp plan_chain_feature(%{mode: :plan_chain}), do: 1.0
  defp plan_chain_feature(_features), do: 0.0
end
