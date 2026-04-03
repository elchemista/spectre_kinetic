defmodule SpectreKinetic.Reranker.Calibration do
  @moduledoc """
  Emits basic selection thresholds from labeled reranker scores.
  """

  @default_quantile 0.1

  @doc """
  Builds calibration metadata from `%{score: float(), label: 0 | 1}` examples.
  """
  @spec build([map()], keyword()) :: map()
  def build(scored_examples, opts \\ []) when is_list(scored_examples) do
    quantile = Keyword.get(opts, :positive_quantile, @default_quantile)

    positives =
      scored_examples
      |> Enum.filter(&truthy_label?(&1[:label] || &1["label"]))
      |> Enum.map(&(&1[:score] || &1["score"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    negatives =
      scored_examples
      |> Enum.reject(&truthy_label?(&1[:label] || &1["label"]))
      |> Enum.map(&(&1[:score] || &1["score"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    %{
      positive_count: length(positives),
      negative_count: length(negatives),
      reranker_accept_threshold: quantile_value(positives, quantile),
      reranker_reject_threshold: quantile_value(negatives, 1.0 - quantile),
      generated_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  defp truthy_label?(1), do: true
  defp truthy_label?(1.0), do: true
  defp truthy_label?(true), do: true
  defp truthy_label?(_value), do: false

  defp quantile_value([], _quantile), do: nil

  defp quantile_value(sorted_values, quantile) do
    index =
      sorted_values
      |> length()
      |> Kernel.-(1)
      |> Kernel.*(quantile)
      |> round()

    Enum.at(sorted_values, max(index, 0))
  end
end
