defmodule Mix.Tasks.Spectre.TrainReranker do
  use Mix.Task

  @moduledoc false
  @shortdoc false

  @impl Mix.Task
  def run(argv) do
    Mix.shell().info(
      "mix spectre.train_reranker is deprecated; use mix spectre_kinetic.train_reranker"
    )

    Mix.Task.run("spectre_kinetic.train_reranker", argv)
  end
end
