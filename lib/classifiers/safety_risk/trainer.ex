defmodule SpectreKinetic.Classifiers.SafetyRisk.Trainer do
  @moduledoc """
  Trainer for the `SafetyRisk` classifier.
  """

  alias SpectreKinetic.Classifiers.Internal.Trainer
  alias SpectreKinetic.Classifiers.SafetyRisk

  @doc """
  Trains the safety-risk classifier from numeric feature rows.
  """
  @spec train([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def train(examples, opts) do
    Trainer.train_multiclass(
      SafetyRisk,
      examples,
      Keyword.put_new(opts, :labels, SafetyRisk.labels())
    )
  end
end
