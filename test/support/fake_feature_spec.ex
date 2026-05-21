defmodule SpectreKinetic.TestFakeFeatureSpec do
  @moduledoc false

  alias SpectreKinetic.Classifiers.Internal.FeatureVector

  use SpectreKinetic.Classifiers.Internal.FeatureSpec

  feature(:bias, :bias_feature)
  feature(:score, :score_feature)

  @doc """
  Builds a tiny feature vector for internal macro tests.
  """
  @spec build(map()) :: [float()]
  def build(features) when is_map(features), do: feature_values(features)

  @spec bias_feature(map()) :: float()
  defp bias_feature(_features), do: 1.0

  @spec score_feature(map()) :: float()
  defp score_feature(features), do: FeatureVector.number(features[:score])
end
