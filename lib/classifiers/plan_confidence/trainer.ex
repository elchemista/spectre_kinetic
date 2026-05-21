defmodule SpectreKinetic.Classifiers.PlanConfidence.Trainer do
  @moduledoc """
  Trainer for the `PlanConfidence` classifier.
  """

  alias SpectreKinetic.Classifiers.Internal.Trainer
  alias SpectreKinetic.Classifiers.PlanConfidence

  @doc """
  Trains the plan-confidence classifier from numeric feature rows.
  """
  @spec train([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def train(examples, opts), do: Trainer.train_binary(PlanConfidence, examples, opts)
end
