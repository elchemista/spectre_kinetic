defmodule SpectreKinetic.Classifiers.BuiltIn do
  @moduledoc """
  Registry for optional built-in classifier modules.

  The public classifier extension API remains the plug behaviour. This registry
  exists so bundled Axon classifiers can share training and dataset wiring
  without leaking Axon internals into core planning.
  """

  alias SpectreKinetic.Classifiers.PlanConfidence
  alias SpectreKinetic.Classifiers.SafetyRisk
  alias SpectreKinetic.Classifiers.SlotConfidence

  @type entry :: %{
          required(:id) => binary(),
          required(:classifier) => module(),
          required(:dataset_path) => binary(),
          required(:feature_module) => module(),
          required(:trainer) => module(),
          optional(:labels) => [atom()]
        }

  @doc """
  Returns all built-in classifier registry entries.
  """
  @spec all() :: [entry()]
  def all, do: entries()

  @doc """
  Fetches a built-in classifier entry by id.
  """
  @spec fetch(binary()) :: {:ok, entry()} | :error
  def fetch(id) when is_binary(id) do
    case Enum.find(entries(), &(&1.id == id)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc """
  Fetches a built-in classifier entry by id, raising when unknown.
  """
  @spec fetch!(binary()) :: entry()
  def fetch!(id) when is_binary(id) do
    case fetch(id) do
      {:ok, entry} -> entry
      :error -> raise ArgumentError, "unsupported classifier #{inspect(id)}"
    end
  end

  @doc """
  Returns built-in classifier ids in training-task order.
  """
  @spec ids() :: [binary()]
  def ids, do: Enum.map(entries(), & &1.id)

  @spec entries() :: [entry()]
  defp entries do
    [
      %{
        id: "plan_confidence",
        classifier: PlanConfidence,
        feature_module: PlanConfidence.Features,
        trainer: PlanConfidence.Trainer,
        dataset_path: dataset_path("plan_confidence.jsonl")
      },
      %{
        id: "slot_confidence",
        classifier: SlotConfidence,
        feature_module: SlotConfidence.Features,
        trainer: SlotConfidence.Trainer,
        dataset_path: dataset_path("slot_confidence.jsonl")
      },
      %{
        id: "safety_risk",
        classifier: SafetyRisk,
        feature_module: SafetyRisk.Features,
        trainer: SafetyRisk.Trainer,
        dataset_path: dataset_path("safety_risk.jsonl"),
        labels: SafetyRisk.labels()
      }
    ]
  end

  defp dataset_path(file_name) do
    :spectre_kinetic
    |> :code.priv_dir()
    |> priv_dir!()
    |> Path.join("dataset")
    |> Path.join(file_name)
  end

  defp priv_dir!(path) when is_list(path), do: List.to_string(path)

  defp priv_dir!({:error, reason}) do
    raise "cannot resolve :spectre_kinetic priv directory: #{inspect(reason)}"
  end
end
