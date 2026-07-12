defmodule Mix.Tasks.Spectre.TrainClassifier do
  use Mix.Task

  @moduledoc false
  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    Mix.shell().info(
      "mix spectre.train_classifier is deprecated; use mix spectre_kinetic.train_classifier"
    )

    Mix.Task.run("spectre_kinetic.train_classifier", argv)
  end
end
