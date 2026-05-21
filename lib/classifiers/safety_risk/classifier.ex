defmodule SpectreKinetic.Classifiers.SafetyRisk do
  @moduledoc """
  Axon-backed safety-risk classifier with deterministic hard guards.
  """

  alias SpectreKinetic.Classifiers.Internal.AxonClassifier
  alias SpectreKinetic.Classifiers.Internal.AxonRuntime
  alias SpectreKinetic.Classifiers.SafetyRisk.Features
  alias SpectreKinetic.PlanContext

  use AxonClassifier,
    id: "safety_risk",
    features: Features,
    output: :multiclass,
    opts: [:require_confirmation_for, :halt_on],
    load_error: "failed to load safety risk classifier"

  @labels [
    :safe,
    :external_side_effect,
    :destructive,
    :financial,
    :credential_sensitive,
    :system_mutation,
    :network_action,
    :unknown_risk
  ]

  @risk_rules [
    destructive: ~w(delete remove destroy drop truncate purge wipe),
    financial: ~w(charge invoice payment refund transfer payout bill),
    credential_sensitive: ~w(password token secret credential api_key key),
    system_mutation:
      ~w(install uninstall package apt shell command restart stop start service write chmod chown),
    external_side_effect: ~w(send email sms publish post webhook deploy notify),
    network_action: ~w(http https url api endpoint request download upload)
  ]

  @confirm_risks [
    :external_side_effect,
    :destructive,
    :financial,
    :credential_sensitive,
    :system_mutation,
    :unknown_risk
  ]

  @impl true
  def call(%PlanContext{} = context, %{mode: :axon, runtime: runtime, opts: opts}) do
    with {:ok, probabilities} <- AxonClassifier.predict_one(runtime, Features.build(context)) do
      labels = AxonRuntime.labels(runtime)
      {axon_risk, axon_confidence} = max_label(labels, probabilities)
      {guard_risk, matched_terms} = hard_guard_risk(context)

      {risk, confidence} =
        riskier({guard_risk, confidence(guard_risk, matched_terms)}, {axon_risk, axon_confidence})

      write_result(
        context,
        risk,
        confidence,
        matched_terms,
        opts,
        axon_risk,
        axon_confidence,
        guard_risk
      )
    end
  end

  def call(%PlanContext{} = context, %{mode: :heuristic, opts: opts}) do
    {risk, matched_terms} = hard_guard_risk(context)

    write_result(
      context,
      risk,
      confidence(risk, matched_terms),
      matched_terms,
      opts,
      nil,
      nil,
      risk
    )
  end

  def call(%PlanContext{} = context, opts) do
    {risk, matched_terms} = hard_guard_risk(context)

    write_result(
      context,
      risk,
      confidence(risk, matched_terms),
      matched_terms,
      opts,
      nil,
      nil,
      risk
    )
  end

  @doc """
  Returns risk labels in model output order.
  """
  @spec labels() :: [atom()]
  def labels, do: @labels

  @doc """
  Applies deterministic safety guard rules without model prediction.
  """
  @spec hard_guard_risk(PlanContext.t()) :: {atom(), [binary()]}
  def hard_guard_risk(context), do: classify_risk(context)

  @doc """
  Scores risk-rule matches for feature generation.
  """
  @spec rule_feature_scores(binary()) :: map()
  def rule_feature_scores(text) when is_binary(text) do
    Map.new(@risk_rules, fn {risk, terms} ->
      matched_count = terms |> Enum.count(&contains_term?(text, &1))
      {risk, min(1.0, matched_count / 3)}
    end)
  end

  defp write_result(
         context,
         risk,
         confidence,
         matched_terms,
         opts,
         axon_risk,
         axon_confidence,
         guard_risk
       ) do
    requires_confirmation = risk in Keyword.get(opts, :require_confirmation_for, @confirm_risks)

    result = %{
      risk: risk,
      confidence: confidence,
      axon_confidence: axon_confidence,
      axon_risk: axon_risk,
      hard_guard_risk: guard_risk,
      requires_confirmation: requires_confirmation,
      matched_terms: matched_terms
    }

    context =
      context
      |> PlanContext.put_classifier_result(:safety_risk, result)
      |> maybe_require_confirmation(result)

    if risk in Keyword.get(opts, :halt_on, []) do
      {:halt, context}
    else
      {:ok, context}
    end
  end

  defp classify_risk(context) do
    if is_nil(PlanContext.selected_tool(context)) do
      {:safe, []}
    else
      context
      |> Features.risk_text()
      |> match_risk_rule()
    end
  end

  defp match_risk_rule(text) do
    Enum.find_value(@risk_rules, {:safe, []}, fn {risk, terms} ->
      matched_terms = Enum.filter(terms, &contains_term?(text, &1))
      risk_match(risk, matched_terms)
    end)
  end

  defp risk_match(_risk, []), do: nil
  defp risk_match(risk, matched_terms), do: {risk, matched_terms}

  defp contains_term?(text, term),
    do: Regex.match?(~r/(^|[^a-z0-9_])#{Regex.escape(term)}([^a-z0-9_]|$)/i, text)

  defp confidence(:safe, _matched_terms), do: 0.80
  defp confidence(_risk, matched_terms), do: min(0.99, 0.75 + length(matched_terms) * 0.05)

  defp max_label(labels, probabilities) do
    labels
    |> Enum.zip(probabilities)
    |> Enum.max_by(fn {_label, probability} -> probability end, fn -> {:unknown_risk, 0.0} end)
  end

  defp riskier({guard_risk, guard_confidence}, {axon_risk, axon_confidence}) do
    if risk_rank(guard_risk) > risk_rank(axon_risk) do
      {guard_risk, guard_confidence}
    else
      {axon_risk, axon_confidence}
    end
  end

  defp risk_rank(:safe), do: 0
  defp risk_rank(:unknown_risk), do: 1
  defp risk_rank(:network_action), do: 2
  defp risk_rank(:external_side_effect), do: 3
  defp risk_rank(:system_mutation), do: 4
  defp risk_rank(:credential_sensitive), do: 5
  defp risk_rank(:financial), do: 5
  defp risk_rank(:destructive), do: 5
  defp risk_rank(_risk), do: 1

  defp maybe_require_confirmation(context, %{requires_confirmation: true, risk: risk})
       when context.status == :ok do
    context
    |> Map.put(:status, :needs_confirmation)
    |> PlanContext.add_warning("planned action has #{risk} risk")
  end

  defp maybe_require_confirmation(context, _result), do: context
end
