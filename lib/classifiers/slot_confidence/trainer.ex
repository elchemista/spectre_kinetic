defmodule SpectreKinetic.Classifiers.SlotConfidence.Trainer do
  @moduledoc """
  Trainer for the `SlotConfidence` classifier.
  """

  alias SpectreKinetic.Classifiers.Internal.Trainer
  alias SpectreKinetic.Classifiers.SlotConfidence

  @doc """
  Trains the slot-confidence classifier from numeric feature rows.
  """
  @spec train([map()], keyword()) :: {:ok, map()} | {:error, term()}
  def train(examples, opts), do: Trainer.train_binary(SlotConfidence, examples, opts)
end
