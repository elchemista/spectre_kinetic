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
    {positives, negatives} = partition_scores(scored_examples)

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

  defp partition_scores(scored_examples) do
    scored_examples
    |> Enum.reduce({[], []}, &collect_score/2)
    |> then(fn {positives, negatives} -> {Enum.sort(positives), Enum.sort(negatives)} end)
  end

  defp collect_score(example, partitions) do
    case fetch_score(example) do
      nil ->
        partitions

      score ->
        put_score(partitions, score, truthy_label?(fetch_label(example)))
    end
  end

  defp put_score({positives, negatives}, score, true), do: {[score | positives], negatives}
  defp put_score({positives, negatives}, score, false), do: {positives, [score | negatives]}

  defp fetch_label(example), do: fetch_key(example, :label, "label")
  defp fetch_score(example), do: fetch_key(example, :score, "score")

  defp fetch_key(example, atom_key, string_key) do
    cond do
      Map.has_key?(example, atom_key) -> Map.get(example, atom_key)
      Map.has_key?(example, string_key) -> Map.get(example, string_key)
      true -> nil
    end
  end

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
