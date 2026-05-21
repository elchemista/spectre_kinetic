defmodule SpectreKinetic.Classifiers.Internal.Dataset do
  @moduledoc false

  alias SpectreKinetic.PlanContext

  @type training_example :: %{required(:features) => [number()], required(:label) => term()}

  @doc false
  @spec load!(map(), binary()) :: [training_example()]
  def load!(entry, path) when is_map(entry) and is_binary(path) do
    path
    |> File.stream!()
    |> Stream.map(&String.trim/1)
    |> Stream.reject(&(&1 == ""))
    |> Stream.map(&Jason.decode!/1)
    |> Enum.map(&compile_example!(entry, &1))
  end

  @spec compile_example!(map(), map()) :: training_example()
  defp compile_example!(_entry, %{"features" => features, "label" => label})
       when is_list(features) do
    %{features: features, label: label}
  end

  defp compile_example!(%{id: "plan_confidence", feature_module: feature_module}, row) do
    row
    |> context()
    |> build_example(feature_module, row)
  end

  defp compile_example!(%{id: "safety_risk", feature_module: feature_module}, row) do
    row
    |> context()
    |> build_example(feature_module, row)
  end

  defp compile_example!(%{id: "slot_confidence", feature_module: feature_module}, row) do
    %{
      features: feature_module.build(context(row), Map.fetch!(row, "arg")),
      label: Map.fetch!(row, "label")
    }
  end

  @spec build_example(PlanContext.t(), module(), map()) :: training_example()
  defp build_example(%PlanContext{} = context, feature_module, row) do
    %{features: feature_module.build(context), label: Map.fetch!(row, "label")}
  end

  @spec context(map()) :: PlanContext.t()
  defp context(row) do
    planner_result = planner_result(row)

    %PlanContext{
      runtime: nil,
      input: row["input"] || row["al"] || "",
      mode: mode(row["mode"]),
      planner_result: planner_result,
      status: status(planner_result["status"]),
      metadata: row["metadata"] || %{},
      classifier_results: %{},
      warnings: [],
      halted?: false
    }
  end

  @spec planner_result(map()) :: map()
  defp planner_result(%{"planner_result" => planner_result} = row) when is_map(planner_result) do
    planner_result
    |> Map.put_new("action", row["action"])
    |> Map.put_new("status", row["status"] || "ok")
  end

  defp planner_result(row) do
    scores = row["scores"] || %{}

    %{
      "status" => row["status"] || "ok",
      "selected_tool" => row["selected_tool"],
      "args" => row["args"] || %{},
      "missing" => row["missing"] || [],
      "confidence" => score(row, scores, "confidence"),
      "combined_score" => score(row, scores, "combined_score"),
      "tool_score" => score(row, scores, "tool_score"),
      "mapping_score" => score(row, scores, "mapping_score"),
      "candidates" => row["candidates"] || [],
      "action" => row["action"]
    }
  end

  @spec score(map(), map(), binary()) :: number() | nil
  defp score(row, scores, key), do: Map.get(scores, key) || Map.get(row, key)

  @spec mode(binary() | atom() | nil) :: :plan | :plan_chain
  defp mode(:plan_chain), do: :plan_chain
  defp mode("plan_chain"), do: :plan_chain
  defp mode(_mode), do: :plan

  @spec status(binary() | atom() | nil) :: atom()
  defp status(status) when status in [nil, "", "ok", :ok], do: :ok
  defp status("NO_TOOL"), do: :no_tool
  defp status("MISSING_ARGS"), do: :missing_args
  defp status("AMBIGUOUS_MAPPING"), do: :ambiguous_mapping
  defp status("needs_confirmation"), do: :needs_confirmation
  defp status("needs_clarification"), do: :needs_clarification
  defp status(status) when is_atom(status), do: status

  defp status(status) when is_binary(status) do
    status
    |> String.downcase()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :ok
  end
end
